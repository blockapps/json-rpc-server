{-# LANGUAGE OverloadedStrings #-}

module Main (main) where

import Network.JsonRpc.Server
import TestTypes
import qualified TestParallelism as P
import Data.Maybe
import Data.List (sortBy)
import Data.Function (on)
import Data.Aeson
import Data.Aeson.Types
import Data.Text (Text)
import qualified Data.ByteString.Lazy.Char8 as B
import qualified Data.HashMap.Strict as H
import Control.Applicative
import Control.Monad.Trans
import Control.Monad.State
import Control.Monad.Identity
import Test.HUnit hiding (State)
import Test.Framework
import Test.Framework.Providers.HUnit

main :: IO ()
main = defaultMain [ testCase "encode RPC error" testEncodeRpcError
                   , testCase "encode error with data" testEncodeErrorWithData
                   , testCase "invalid JSON" testInvalidJson
                   , testCase "invalid JSON RPC" testInvalidJsonRpc
                   , testCase "empty batch call" testEmptyBatchCall
                   , testCase "wrong version in request" testWrongVersion
                   , testCase "method not found" testMethodNotFound
                   , testCase "wrong method name capitalization" testWrongMethodNameCapitalization
                   , testCase "missing required named argument" testMissingRequiredNamedArg
                   , testCase "missing required unnamed argument" testMissingRequiredUnnamedArg
                   , testCase "wrong argument type" testWrongArgType
                   , testCase "disallow extra unnamed arguments" testDisallowExtraUnnamedArg
                   , testCase "invalid notification" testNoResponseToInvalidNotification
                   , testCase "batch request" testBatch
                   , testCase "batch notifications" testBatchNotifications
                   , testCase "allow missing version" testAllowMissingVersion
                   , testCase "no arguments" testNoArgs
                   , testCase "empty argument array" testEmptyUnnamedArgs
                   , testCase "empty argument object" testEmptyNamedArgs
                   , testCase "allow extra named argument" testAllowExtraNamedArg
                   , testCase "use default named argument" testDefaultNamedArg
                   , testCase "use default unnamed argument" testDefaultUnnamedArg
                   , testCase "null request ID" testNullId
                   , testCase "parallelize tasks" P.testParallelizingTasks ]
                   
testEncodeRpcError :: Assertion
testEncodeRpcError = fromByteString (encode err) @?= Just testError
    where err = rpcError (-1) "error"
          testError = TestRpcError (-1) "error" Nothing

testEncodeErrorWithData :: Assertion
testEncodeErrorWithData = fromByteString (toByteString err) @?= Just testError
    where err = rpcErrorWithData 1 "my message" errorData
          testError = TestRpcError 1 "my message" $ Just $ toJSON errorData
          errorData = ('\x03BB', [True], ())

testInvalidJson :: Assertion
testInvalidJson = checkResponseWithSubtract "5" idNull (-32700)

testInvalidJsonRpc :: Assertion
testInvalidJsonRpc = checkResponseWithSubtract (encode $ object ["id" .= (10 :: Int)]) idNull (-32600)

testEmptyBatchCall :: Assertion
testEmptyBatchCall = checkResponseWithSubtract (encode emptyArray) idNull (-32600)

testWrongVersion :: Assertion
testWrongVersion = checkResponseWithSubtract (encode requestWrongVersion) idNull (-32600)
    where requestWrongVersion = Object $ H.insert versionKey (String "1") hm
          Object hm = toJSON $ subtractRequestNamed [("a1", Number 4)] (idNumber 10)

testMethodNotFound :: Assertion
testMethodNotFound = checkResponseWithSubtract (encode request) i (-32601)
    where request = TestRequest "ad" (Just [Number 1, Number 2]) (Just i)
          i = idNumber 3

testWrongMethodNameCapitalization :: Assertion
testWrongMethodNameCapitalization = checkResponseWithSubtract (encode request) i (-32601)
    where request = TestRequest "Add" (Just [Number 1, Number 2]) (Just i)
          i = idNull

testMissingRequiredNamedArg :: Assertion
testMissingRequiredNamedArg = checkResponseWithSubtract (encode request) i (-32602)
    where request = subtractRequestNamed [("A1", Number 1), ("a2", Number 20)] i
          i = idNumber 2

testMissingRequiredUnnamedArg :: Assertion
testMissingRequiredUnnamedArg = checkResponseWithSubtract (encode request) i (-32602)
    where request = TestRequest "subtract 2" (Just [Number 0]) (Just i)
          i = idString ""

testWrongArgType :: Assertion
testWrongArgType = checkResponseWithSubtract (encode request) i (-32602)
    where request = subtractRequestNamed [("a1", Number 1), ("a2", Bool True)] i
          i = idString "ABC"

testDisallowExtraUnnamedArg :: Assertion
testDisallowExtraUnnamedArg = checkResponseWithSubtract (encode request) i (-32602)
    where request = subtractRequestUnnamed (map Number [1, 2, 3]) i
          i = idString "i"

testNoResponseToInvalidNotification :: Assertion
testNoResponseToInvalidNotification = runIdentity response @?= Nothing
    where response = call (toMethods [subtractMethod]) $ encode request
          request = TestRequest "12345" (Nothing :: Maybe ()) Nothing

testBatch :: Assertion
testBatch = sortBy (compare `on` fromIntId) (fromJust (fromByteString =<< runIdentity response)) @?= expected
       where expected = [TestResponse i1 (Right $ Number 2), TestResponse i2 (Right $ Number 4)]
             response = call (toMethods [subtractMethod]) $ encode request
             request = [subtractRequestNamed (toArgs 10 8) i1, subtractRequestNamed (toArgs 24 20) i2]
             toArgs x y = [("a1", Number x), ("a2", Number y)]
             i1 = idNumber 1
             i2 = idNumber 2
             fromIntId rsp = (fromNumId $ rspId rsp) :: Maybe Int

testBatchNotifications :: Assertion
testBatchNotifications = runState response 0 @?= (Nothing, 10)
    where response = call (toMethods [incrementStateMethod]) $ encode request
          request = replicate 10 $ TestRequest "increment" (Nothing :: Maybe ()) Nothing

testAllowMissingVersion :: Assertion
testAllowMissingVersion = (fromByteString =<< runIdentity response) @?= (Just $ TestResponse i (Right $ Number 1))
    where requestNoVersion = Object $ H.delete versionKey hm
          Object hm = toJSON $ subtractRequestNamed [("a1", Number 1)] i
          response = call (toMethods [subtractMethod]) $ encode requestNoVersion
          i = idNumber (-1)

testAllowExtraNamedArg :: Assertion
testAllowExtraNamedArg = (fromByteString =<< runIdentity response) @?= (Just $ TestResponse i (Right $ Number (-10)))
    where response = call (toMethods [subtractMethod]) $ encode request
          request = subtractRequestNamed args i
          args = [("a1", Number 10), ("a2", Number 20), ("a3", String "extra")]
          i = idString "ID"

testDefaultNamedArg :: Assertion
testDefaultNamedArg = (fromByteString =<< runIdentity response) @?= (Just $ TestResponse i (Right $ Number 1000))
    where response = call (toMethods [subtractMethod]) $ encode request
          request = subtractRequestNamed args i
          args = [("a", Number 500), ("a1", Number 1000)]
          i = idNumber 3

testDefaultUnnamedArg :: Assertion
testDefaultUnnamedArg = (fromByteString =<< runIdentity response) @?= (Just $ TestResponse i (Right $ Number 4))
    where response = call (toMethods [subtractMethod]) $ encode request
          request = subtractRequestUnnamed [Number 4] i
          i = idNumber 0

testNullId :: Assertion
testNullId = (fromByteString =<< runIdentity response) @?= (Just $ TestResponse idNull (Right $ Number (-80)))
    where response = call (toMethods [subtractMethod]) $ encode request
          request = subtractRequestNamed args idNull
          args = [("a2", Number 70), ("a1", Number (-10))]

testNoArgs :: Assertion
testNoArgs = compareGetTimeResult Nothing

testEmptyUnnamedArgs :: Assertion
testEmptyUnnamedArgs = compareGetTimeResult $ Just $ Right empty

testEmptyNamedArgs :: Assertion
testEmptyNamedArgs = compareGetTimeResult $ Just $ Left H.empty

incrementStateMethod :: Method (State Int)
incrementStateMethod = toMethod "increment" f ()
    where f :: RpcResult (State Int) ()
          f = lift $ modify (+1)

compareGetTimeResult :: Maybe (Either Object Array) -> Assertion
compareGetTimeResult requestArgs = assertEqual "unexpected rpc response" expected =<<
                                   ((fromByteString . fromJust) <$> call (toMethods [getTimeMethod]) (encode getTimeRequest))
    where expected = Just $ TestResponse i (Right $ Number 100)
          getTimeRequest = TestRequest "get_time_seconds" requestArgs (Just i)
          i = idString "Id 1"

subtractRequestNamed :: [(Text, Value)] -> TestId -> TestRequest
subtractRequestNamed args i = TestRequest "subtract 1" (Just $ H.fromList args) (Just i)

subtractRequestUnnamed :: [Value] -> TestId -> TestRequest
subtractRequestUnnamed args i = TestRequest "subtract 1" (Just args) (Just i)

checkResponseWithSubtract :: B.ByteString -> TestId -> Int -> Assertion
checkResponseWithSubtract input expectedId expectedCode = do
  rspId <$> res2 @?= Just expectedId
  (getErrorCode =<< res2) @?= Just expectedCode
      where res1 :: Identity (Maybe B.ByteString)
            res1 = call (toMethods [subtractMethod, flippedSubtractMethod]) input
            res2 = fromByteString =<< runIdentity res1

fromByteString :: FromJSON a => B.ByteString -> Maybe a
fromByteString str = case fromJSON <$> decode str of
                     Just (Success x) -> Just x
                     _ -> Nothing

toByteString :: ToJSON a => a -> B.ByteString
toByteString = encode . toJSON

getErrorCode :: TestResponse -> Maybe Int
getErrorCode (TestResponse _ (Left (TestRpcError code _ _))) = Just code
getErrorCode _ = Nothing

subtractMethod :: Method Identity
subtractMethod = toMethod "subtract 1" sub (Required "a1" :+: Optional "a2" 0 :+: ())
            where sub :: Int -> Int -> RpcResult Identity Int
                  sub x y = return (x - y)

flippedSubtractMethod :: Method Identity
flippedSubtractMethod = toMethod "subtract 2" sub (Optional "y" (-1000) :+: Required "x" :+: ())
            where sub :: Int -> Int -> RpcResult Identity Int
                  sub y x = return (x - y)

getTimeMethod :: Method IO
getTimeMethod = toMethod "get_time_seconds" getTime ()
    where getTime :: RpcResult IO Integer
          getTime = liftIO getTestTime

getTestTime :: IO Integer
getTestTime = return 100
