-- | Creates and seeds the example database: @hmssql-example-setup@.
module Main (main) where

import System.Environment (getArgs)
import System.Exit (exitFailure)
import System.IO (hPutStrLn, stderr)

import ShopDb (setupDatabase)

-- | Arguments are refused rather than ignored: the setup drops and recreates
-- every table, and @stack run export@ in a project with this executable runs
-- it, not the program the arguments were meant for.
main :: IO ()
main = getArgs >>= \case
  [] -> setupDatabase
  args -> do
    hPutStrLn stderr ("hmssql-example-setup takes no arguments, and was given " ++ unwords args)
    hPutStrLn stderr "It drops, recreates and seeds the example tables in MSSQL_DATABASE."
    hPutStrLn stderr "With stack run, name the executable: stack run <executable> -- <arguments>"
    exitFailure
