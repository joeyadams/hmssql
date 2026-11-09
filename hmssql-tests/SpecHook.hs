-- | Applied by hspec-discover to the whole suite: decides which spec items
-- run in parallel and which run alone, scales the default number of
-- property cases ('TestDb.propertyScale'), and skips the tests that need a
-- server when there is none ('TestDb.noServerHook').
--
-- Every item runs in parallel with other items (up to @--jobs@ at a time)
-- unless it is marked serial: its module is in 'serialModules', or the item
-- (or a group around it) is wrapped in 'TestDb.serial' (hspec's
-- 'sequential').  The serial items are moved after all the parallel ones,
-- keeping their order, so that each runs alone: hspec starts a non-parallel
-- item only when its report reaches it, and by then every parallel item
-- (all of them earlier in the tree) has finished.  So the report lists the
-- parallel items first, then the serial ones; a module with both appears
-- twice, under the same name.  Item paths (for @--match@, @--skip@ and
-- @--rerun@) don't change.
--
-- A group with an 'afterAll' or 'aroundAll' hook moves as a whole: if any
-- item in it is serial, all of it is.  Its items still run in parallel with
-- each other, so what a 'beforeAll' or 'aroundAll' hook hands them (a
-- connection, a table the test assumes it owns) is used by several at once;
-- give each item its own with 'around' instead.
--
-- @--jobs N@ (@-j N@) sets how many items run at once (default
-- 'defaultJobs'); @-j1@ runs one item at a time, in order.
--
-- With a server (@HMSSQL_TEST_PASSWORD@ set), the hook also creates the
-- shared test database if needed and applies every fixture declared with
-- 'TestDb.withFixture' ('TestDb.prepareTestDb') before any item runs, so
-- that no test (a timed one in particular) waits for that setup.  If it
-- fails, the run stops there.  Then it prints the configuration the run
-- uses ('configurationLine'), so a log says what it is a log of.
module SpecHook (hook, serialModules, startFirst) where

import Control.Concurrent (rtsSupportsBoundThreads, threadDelay)
import Control.Exception (SomeException, catch, displayException, throwIO)
import Control.Monad (unless, when)
import Data.Foldable (toList)
import Data.List (isInfixOf, isPrefixOf, isSuffixOf, partition)
import Data.Maybe (fromMaybe)
import Data.Monoid (Endo (..))
import Test.Hspec
import Test.Hspec.Core.Runner (Config (..))
import Test.Hspec.Core.Spec (Item (..), SpecTree, Tree (..), fromSpecList, modifyConfig, runSpecM)

import Data.Text (Text)
import qualified Data.Text as T
import GHC.IO.Encoding (setLocaleEncoding)
import System.IO (hPutStrLn, hSetEncoding, stderr, stdout, utf8)

import Hmssql (Encryption (..))
import Hmssql.Connection.Backend (networkTcp)

import Compat (onWindows)
import TestDb

-- | Modules whose items must run alone, by their hspec-discover name
-- (@"Resources.Leaks"@ for @hmssql-tests/Resources/LeaksSpec.hs@).  An entry ending
-- in @.@ names every module under it (@"Resources."@).  A name that matches
-- no module is an error, so that renaming a module can't silently make it
-- parallel.
--
-- A module belongs here when its items (or most of them) measure something
-- that items running at the same time would disturb: wall-clock deadlines
-- or timing ratios, allocation or residency (the RTS counters are
-- process-wide), thread or file-descriptor counts.  Tests that change only
-- server state of their own (#temp tables, 'TestDb.uniqueName' objects,
-- scratch databases, their own sessions, found by a unique application
-- name) can run in parallel.  For a few such items in an otherwise parallel
-- module, wrap just those in 'TestDb.serial' instead.
serialModules :: [String]
serialModules =
  [ "Concurrency.Cancel" -- "promptly": wall-clock bounds on cancellation
  , "Resources." -- threads, descriptors, heap and process-wide allocation
  , "Scale.HugeBinary" -- time and residency with 1 GiB values
  , "Scale.ManyResultSets" -- residency
  , "Scale.Materialized" -- a time bound
  , "Scale.RepeatedQueries" -- residency over many queries
  , "Scale.StreamingResidency" -- residency
  , "Scale.TlsSmallPacketMemory" -- live heap after a read
  ]

-- | Modules with long parallel items, started (and reported) before the
-- rest of the parallel items: hspec starts parallel items in the order of
-- the tree, so a long item near the end would still be running after all
-- the others had finished.  Same form as 'serialModules'.
startFirst :: [String]
startFirst =
  [ "Model." -- 150 and 100 random operation sequences: 15-30 s
  ]

-- | Items running at once by default.  Most live items spend their time
-- waiting for the server, so more than the number of cores pays off.
--
-- Without @-threaded@ every item shares one capability, and a thread whose
-- read was waiting goes to the back of the run queue when it ends, behind
-- every item that is computing: at 16 the 64 MB reads of "LargeValue"
-- (2.5 s alone) took more than their 60 s, and "Mars.WithQueryS" never
-- caught the exit's wait in 50 tries.  At 4 both passed, and the suite
-- took 368 s where 16 took 458 s (Windows, SQL Server 2019, 2026-11-06).
defaultJobs :: Int
defaultJobs = if rtsSupportsBoundThreads then 16 else 4

hook :: Spec -> Spec
hook spec = do
  (Endo config, trees) <- runIO (runSpecM spec)
  let names = [name | Node name _ <- trees]
      unknown = [m | m <- serialModules ++ startFirst, not (any (matches m) names)]
  unless (null unknown) $
    runIO (fail ("hmssql-tests/SpecHook.hs: no module matches " ++ show unknown))
  -- Hedgehog's reports draw boxes and bars (U+250F, U+2588).  In a
  -- container with no locale, stdout is ASCII, and the first such report
  -- killed the run.
  runIO $ mapM_ (`hSetEncoding` utf8) [stdout, stderr]
  -- Hedgehog also reads the property's source file for its report, in the
  -- locale's encoding.  With no locale, a failure in a module that has a
  -- character beyond ASCII was reported as an IOException from
  -- hGetContents, in place of the failing case.
  runIO $ setLocaleEncoding utf8
  -- After runSpecM, which declared the fixtures.
  runIO $ do
    configured <- testServerConfigured
    when configured $ waitingForPipes prepareTestDb `catch` \(e :: SomeException) -> do
      hint <- strictEncryptionHint e `catch` \(_ :: SomeException) -> pure ""
      fail ("hmssql-tests/SpecHook.hs: setting up the test database failed: " ++ displayException e ++ hint)
    waitingForPipes (configurationLine configured) >>= hPutStrLn stderr
  modifyConfig $ \c ->
    let c' = config c in c' {configConcurrentJobs = Just (fromMaybe defaultJobs (configConcurrentJobs c'))}
  let (first, rest) = partition (\case Node name _ -> any (`matches` name) startFirst; _ -> False) trees
      (par, ser) = unzip (map (partitionTree . markModule) (first ++ rest))
  noServerHook $ scaleDefaultPropertyCases $ fromSpecList (concat par ++ concat ser)
  where
    matches m name
      | "." `isSuffixOf` m = m `isPrefixOf` name
      | otherwise = m == name
    markModule t = case t of
      Node name _ | any (`matches` name) serialModules -> fmap (setParallel False) t
      _ -> fmap (setParallel True) t

-- | Mark an item unless it is marked already (inner marks win, as with
-- hspec's 'parallel' and 'sequential').
setParallel :: Bool -> Item a -> Item a
setParallel p item = case itemIsParallelizable item of
  Nothing -> item {itemIsParallelizable = Just p}
  Just _ -> item

isSerial :: Item a -> Bool
isSerial item = itemIsParallelizable item /= Just True

-- | Split a tree into its parallel part and its serial part (either may be
-- empty), keeping the groups around them.
partitionTree :: SpecTree a -> ([SpecTree a], [SpecTree a])
partitionTree = \case
  Leaf item
    | isSerial item -> ([], [Leaf item])
    | otherwise -> ([Leaf item], [])
  Node name xs ->
    let (ps, ss) = unzip (map partitionTree xs)
    in (group name (concat ps), group name (concat ss))
  t@NodeWithCleanup {}
    | any isSerial (toList t) -> ([], [fmap (\i -> i {itemIsParallelizable = Just False}) t])
    | otherwise -> ([t], [])
  where
    group name ys = [Node name ys | not (null ys)]

-- | One line on what the run tests against: the server and its databases,
-- the connection settings every test connection gets (MARS among them),
-- and whether the slow tests run.
-- | Run the suite's setup, waiting out a server that for the moment isn't
-- taking pipe connections.  SQL Server on Windows was seen to refuse the
-- first connections over Shared Memory or Named Pipes after an idle
-- spell, and then to stop listening on the pipe for up to a minute, for
-- Microsoft's own client as much as for hmssql
-- (docs/dev/windows-research.md).  The suite's first connection is made
-- here, so without the wait a run often ended before its first test.
-- Each wait is printed, with the failure, so that it can be checked
-- against the server's log.  Only the two failures that outage produces
-- are waited for, for up to two minutes; anything else is thrown at once.
waitingForPipes :: IO a -> IO a
waitingForPipes act = go (1 :: Int)
  where
    attempts = 13
    go n = act `catch` \(e :: SomeException) ->
      if n < attempts && pipeOutage e
        then do
          hPutStrLn stderr $ "hmssql tests: the server is not taking pipe connections ("
            ++ takeWhile (/= '\n') (displayException e) ++ "); waiting 10 s before attempt "
            ++ show (n + 1) ++ " of " ++ show attempts
          threadDelay 10_000_000
          go (n + 1)
        else throwIO e
    pipeOutage e = any (`isInfixOf` displayException e)
      ["No process is on the other end of the pipe", "All pipe instances are busy"]

-- | What to add to the setup's failure when it is probably a server that
-- has no strict encryption: such a server closes the connection at the
-- TLS ClientHello, which says nothing of the cause.
strictEncryptionHint :: SomeException -> IO String
strictEncryptionHint e = do
  enc <- testEncryption
  pure $ if enc == EncryptStrict &&"the server closed the connection" `isInfixOf` displayException e
    then "\nThe test connection uses strict encryption (TDS 8.0), which SQL Server 2017 and 2019, and SQL Server 2022 on \
         \Linux, don't have: set HMSSQL_TEST_SQL_VERSION=2017, 2019 or 2022 for such a server."
    else ""

configurationLine :: Bool -> IO String
configurationLine configured = do
  slowOn <- slowTestsEnabled
  let slowWord = "slow tests " ++ onOff slowOn
  if not configured
    then pure ("hmssql tests: no server (HMSSQL_TEST_PASSWORD unset): pure and mock tests only; " ++ tcpPath ++ slowWord)
    else do
      host <- testHost
      azure <- testServerIsAzure
      db <- testDatabaseName
      companion <- testCompanionDatabaseName
      enc <- testEncryption
      trustCert <- testTrustServerCertificate
      size <- testPacketSize
      setup <- testSessionSetup
      mars <- testMars
      window <- testMarsWindow
      protocol <- testProtocolName
      -- What the server says the connection came in on: with "auto" that
      -- depends on what the server has enabled, and a run should say
      -- which transport it covered.
      transport <- testNetTransport
      pure $ concat
        [ "hmssql tests: ", if azure then "Azure SQL Database " else "SQL Server ", T.unpack host
        , ", database ", T.unpack db, " (companion ", T.unpack companion, "); "
        , "protocol ", protocol, " (the server reports ", T.unpack transport, "), "
        , "MARS ", onOff mars, if mars then " (window " ++ show window ++ ")" else "", ", ", show enc, ", packet size ", show size
        , ", trust server certificate ", onOff trustCert
        , ", session setup ", setupWords setup, "; ", tcpPath, slowWord ]
  where
    onOff b = if b then "on" else "off"
    -- On Windows, which of the two I/O paths the run covers.
    tcpPath
      | not onWindows = ""
      | networkTcp = "TCP through network's calls and the pipes through GHC's native I/O manager; "
      | otherwise = "TCP and the pipes through hmssql's overlapped I/O; "
    setupWords :: [Text] -> String
    setupWords [] = "none"
    setupWords ss = show (T.intercalate "; " ss)
