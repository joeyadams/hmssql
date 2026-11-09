{-# LANGUAGE MagicHash #-}
{-# LANGUAGE DerivingStrategies #-}
-- | The helpers of "Hmssql.Internal.Derived" do what derived Show and Eq
-- do.  The library's own instances are written with them (in place of
-- deriving, for code size), and their output must stay the derived one,
-- character for character: users and tests read it.
--
-- Each type here has a twin: one derives Show and Eq, and the other has the
-- same fields and instances written with the helpers, its Show under the
-- derived twin's constructor and field names.  The two must show alike at
-- every precedence, and compare alike.
module InternalDerivedSpec (spec) where

import Data.Int (Int8)
import Data.Text (Text)
import qualified Data.Text as T
import Data.Word (Word16)
import Hedgehog (Gen, forAll, (===))
import qualified Hedgehog.Gen as Gen
import qualified Hedgehog.Range as Range
import Test.Hspec
import Test.Hspec.Hedgehog (hedgehog)

import Hmssql.Internal.Derived

data DerivedRecord = DerivedRecord
  { drInt :: !Int, drText :: !Text, drMaybe :: !(Maybe Int8), drWord :: !Word16 }
  deriving stock (Eq, Show)

data HandRecord = HandRecord !Int !Text !(Maybe Int8) !Word16

instance Show HandRecord where
  showsPrec p (HandRecord a b c e) =
    showRecord p "DerivedRecord"# ["drInt"# := a, "drText"# := b, "drMaybe"# := c, "drWord"# := e]
  {-# OPAQUE showsPrec #-}

data DerivedSum
  = DNullary
  | DOne !Int
  | DTwo !(Maybe Int) !Text
  | DThree !Int8 ![Int] !DerivedRecord
  | DRec { dsField :: !Int }
  | DRecTwo { dsLeft :: !(Maybe Int), dsRight :: !DerivedSum }
  deriving stock (Eq, Show)

data HandSum
  = HNullary
  | HOne !Int
  | HTwo !(Maybe Int) !Text
  | HThree !Int8 ![Int] !HandRecord
  | HRec !Int
  | HRecTwo !(Maybe Int) !HandSum

instance Show HandSum where
  showsPrec p = \case
    HNullary -> showString "DNullary"
    HOne a -> showCon1 p "DOne"# a
    HTwo a b -> showCon p "DTwo"# [Arg a, Arg b]
    HThree a b c -> showCon p "DThree"# [Arg a, Arg b, Arg c]
    HRec a -> showRecord p "DRec"# ["dsField"# := a]
    HRecTwo a b -> showRecord p "DRecTwo"# ["dsLeft"# := a, "dsRight"# := b]
  {-# OPAQUE showsPrec #-}

-- As the library's are written: a field of a small primitive type compared
-- inline, any other through 'eq'.
instance Eq HandRecord where
  HandRecord a b c e == HandRecord a' b' c' e' = a == a' && eq b b' && eq c c' && e == e'
  {-# OPAQUE (==) #-}

instance Eq HandSum where
  x == y = case (x, y) of
    (HNullary, HNullary) -> True
    (HOne a, HOne a') -> a == a'
    (HTwo a b, HTwo a' b') -> eq a a' && eq b b'
    (HThree a b c, HThree a' b' c') -> a == a' && eq b b' && eq c c'
    (HRec a, HRec a') -> a == a'
    (HRecTwo a b, HRecTwo a' b') -> eq a a' && eq b b'
    _ -> False
  {-# OPAQUE (==) #-}

genRecords :: Gen (DerivedRecord, HandRecord)
genRecords = do
  a <- Gen.int (Range.linearFrom 0 minBound maxBound)
  b <- T.pack <$> Gen.string (Range.linear 0 8) Gen.unicode
  c <- Gen.maybe (Gen.int8 Range.linearBounded)
  e <- Gen.word16 Range.linearBounded
  pure (DerivedRecord a b c e, HandRecord a b c e)

genSums :: Gen (DerivedSum, HandSum)
genSums = Gen.recursive Gen.choice
  [ pure (DNullary, HNullary)
  , (\a -> (DOne a, HOne a)) <$> int
  , (\a b -> (DTwo a b, HTwo a b)) <$> Gen.maybe int <*> (T.pack <$> Gen.string (Range.linear 0 5) Gen.ascii)
  , (\a b (r, r') -> (DThree a b r, HThree a b r')) <$> Gen.int8 Range.linearBounded
      <*> Gen.list (Range.linear 0 3) int <*> genRecords
  , (\a -> (DRec a, HRec a)) <$> int
  ]
  [ (\a (s, s') -> (DRecTwo a s, HRecTwo a s')) <$> Gen.maybe int <*> genSums ]
  where
    int = Gen.int (Range.linearFrom 0 (-1000) 1000)

spec :: Spec
spec = do
  it "showRecord writes a derived record" $ hedgehog $ do
    (d, h) <- forAll genRecords
    p <- forAll (Gen.element [0, 10, 11])
    showsPrec p h "" === showsPrec p d ""
  it "showCon, showCon1 and showRecord write derived constructors" $ hedgehog $ do
    (d, h) <- forAll genSums
    p <- forAll (Gen.element [0, 10, 11])
    showsPrec p h "" === showsPrec p d ""
    showList [h, h] "" === showList [d, d] ""
    show (Just h) === show (Just d)
  it "an Eq instance written with eq compares as a derived one" $ hedgehog $ do
    (d, h) <- forAll genSums
    -- Half the time the same value, so that equal pairs are tried too.
    (d', h') <- forAll (Gen.choice [pure (d, h), genSums])
    (h == h') === (d == d')
    (h /= h') === (d /= d')
