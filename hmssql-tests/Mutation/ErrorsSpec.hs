-- | Tests found by mutation testing of "Hmssql.Errors".
module Mutation.ErrorsSpec (spec) where

import Control.Exception
import Data.List (isInfixOf)
import Test.Hspec


import Hmssql.Errors
reasonOf :: ConnectionClosed -> String
reasonOf e = case connectionClosedReason e of
  ClosedByServer -> "server"
  ClosedByClient -> "client"
  TransportFailed _ -> "transport"

spec :: Spec
spec = describe "ConnectionClosed" $ do
  it "describes each reason in displayException" $ do
    displayException (ConnectionClosedBy ClosedByServer) `shouldBe` "the server closed the connection"
    displayException (ConnectionClosedBy ClosedByClient) `shouldBe` "the connection was closed by close"

  it "includes the underlying failure of TransportFailed" $ do
    let msg = displayException (ConnectionClosedBy (TransportFailed (toException (userError "cable unplugged"))))
    msg `shouldSatisfy` ("the connection failed: " `isInfixOf`)
    msg `shouldSatisfy` ("cable unplugged" `isInfixOf`)

  it "as an expression, the ConnectionClosed pattern means the server closed it" $
    reasonOf ConnectionClosed `shouldBe` "server"
