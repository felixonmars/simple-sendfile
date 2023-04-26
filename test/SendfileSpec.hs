{-# LANGUAGE CPP #-}
{-# LANGUAGE OverloadedStrings #-}

module SendfileSpec where

import Control.Concurrent
import Control.Exception
import Control.Monad
import Control.Monad.Trans.Resource (MonadResource, runResourceT)
import Data.ByteString.Char8 as BS
import Data.Conduit hiding (connect)
import Data.Conduit.Binary as CB
import Data.Conduit.List as CL
import Data.Conduit.Network
import Data.IORef
import Network.Sendfile
import Network.Socket
import System.Directory
import System.EasyFile
import System.Exit
import System.IO
import System.IO.Temp
import System.Process
import System.Timeout
import Test.Hspec

----------------------------------------------------------------

spec :: Spec
spec = do
    describe "sendfile" $ do
        it "sends an entire file" $ do
            sendFile EntireFile `shouldReturn` ExitSuccess
        it "sends a part of file" $ do
            sendFile (PartOfFile 2000 1000000) `shouldReturn` ExitSuccess
        it "terminates even if length is over" $ do
            shouldTerminate $ sendIllegal (PartOfFile 2000 5000000)
        it "terminates even if offset is over" $ do
            shouldTerminate $ sendIllegal (PartOfFile 5000000 6000000)
        it "terminates even if the file is truncated" $ do
            shouldTerminate truncateFile
    describe "sendfileWithHeader" $ do
        it "sends an header and an entire file" $ do
            sendFileH EntireFile `shouldReturn` ExitSuccess
        it "sends an header and a part of file" $ do
            sendFileH (PartOfFile 2000 1000000) `shouldReturn` ExitSuccess
        it "sends a large header and an entire file" $ do
            sendFileHLarge EntireFile `shouldReturn` ExitSuccess
        it "sends a large header and a part of file" $ do
            sendFileHLarge (PartOfFile 2000 1000000) `shouldReturn` ExitSuccess
        it "terminates even if length is over" $ do
            shouldTerminate $ sendIllegalH (PartOfFile 2000 5000000)
        it "terminates even if offset is over" $ do
            shouldTerminate $ sendIllegalH (PartOfFile 5000000 6000000)
        it "terminates even if the file is truncated" $ do
            shouldTerminate truncateFileH
  where
    fiveSecs = 5000000
    shouldTerminate body = timeout fiveSecs body `shouldReturn` Just ()

----------------------------------------------------------------

sendFile :: FileRange -> IO ExitCode
sendFile range = sendFileCore range []

sendFileH :: FileRange -> IO ExitCode
sendFileH range = sendFileCore range headers
  where
    headers = [
        BS.replicate 100 'a'
      , "\n"
      , BS.replicate 200 'b'
      , "\n"
      , BS.replicate 300 'c'
      , "\n"
      ]

sendFileHLarge :: FileRange -> IO ExitCode
sendFileHLarge range = sendFileCore range headers
  where
    headers = [
        BS.replicate 10000 'a'
      , "\n"
      , BS.replicate 20000 'b'
      , "\n"
      , BS.replicate 30000 'c'
      , "\n"
      ]

sendFileCore :: FileRange -> [ByteString] -> IO ExitCode
sendFileCore range headers = bracket setup teardown $ \(s2,_) -> do
#if MIN_VERSION_conduit(1,3,0)
    runResourceT $ runConduit (sourceSocket s2 .| sinkFile outputFile)
#else
    runResourceT $ sourceSocket s2 $$ sinkFile outputFile
#endif
    runResourceT $ copyfile range
    system $ "cmp -s " ++ outputFile ++ " " ++ expectedFile
  where
    copyfile EntireFile = do
        -- of course, we can use <> here
#if MIN_VERSION_conduit(1,3,0)
        runConduit (sourceList headers .| sinkFile expectedFile)
        runConduit (sourceFile inputFile .| sinkAppendFile expectedFile)
#else
        sourceList headers $$ sinkFile expectedFile
        sourceFile inputFile $$ sinkAppendFile expectedFile
#endif
    copyfile (PartOfFile off len) = do
#if MIN_VERSION_conduit(1,3,0)
        runConduit (sourceList headers .| sinkFile expectedFile)
        runConduit (sourceFile inputFile
                 .| CB.isolate (off' + len')
                 .| (CB.take off' >> sinkAppendFile expectedFile))
#else
        sourceList headers $$ sinkFile expectedFile
        sourceFile inputFile $= CB.isolate (off' + len')
                             $$ (CB.take off' >> sinkAppendFile expectedFile)
#endif
      where
        off' = fromIntegral off
        len' = fromIntegral len
    setup = do
        (s1,s2) <- sockpair
        tid <- forkOS (sf s1 `finally` sendEOF s1)
        return (s2,tid)
      where
        sf s1
          | headers == [] = sendfile s1 inputFile range (return ())
          | otherwise     = sendfileWithHeader s1 inputFile range (return ()) headers
        sendEOF = close
    teardown (s2,tid) = do
        close s2
        killThread tid
        removeFileIfExists outputFile
        removeFileIfExists expectedFile
    inputFile = "test/inputFile"
    outputFile = "test/outputFile"
    expectedFile = "test/expectedFile"

----------------------------------------------------------------

sendIllegal :: FileRange -> IO ()
sendIllegal range = sendIllegalCore range []

sendIllegalH :: FileRange -> IO ()
sendIllegalH range = sendIllegalCore range headers
  where
    headers = [
        BS.replicate 100 'a'
      , "\n"
      , BS.replicate 200 'b'
      , "\n"
      , BS.replicate 300 'c'
      , "\n"
      ]

sendIllegalCore :: FileRange -> [ByteString] -> IO ()
sendIllegalCore range headers = bracket setup teardown $ \(s2,_) -> do
#if MIN_VERSION_conduit(1,3,0)
    runResourceT $ runConduit (sourceSocket s2 .| sinkFile outputFile)
#else
    runResourceT $ sourceSocket s2 $$ sinkFile outputFile
#endif
    return ()
  where
    setup = do
        (s1,s2) <- sockpair
        tid <- forkOS (sf s1 `finally` sendEOF s1)
        return (s2,tid)
      where
        sf s1
          | headers == [] = sendfile s1 inputFile range (return ())
          | otherwise     = sendfileWithHeader s1 inputFile range (return ()) headers
        sendEOF = close
    teardown (s2,tid) = do
        close s2
        killThread tid
        removeFileIfExists outputFile
    inputFile = "test/inputFile"
    outputFile = "test/outputFile"

----------------------------------------------------------------

truncateFile :: IO ()
truncateFile = truncateFileCore []

truncateFileH :: IO ()
truncateFileH = truncateFileCore headers
  where
    headers = [
        BS.replicate 100 'a'
      , "\n"
      , BS.replicate 200 'b'
      , "\n"
      , BS.replicate 300 'c'
      , "\n"
      ]

truncateFileCore :: [ByteString] -> IO ()
truncateFileCore headers = bracket setup teardown $ \(s2,_) -> do
#if MIN_VERSION_conduit(1,3,0)
    runResourceT $ runConduit (sourceSocket s2 .| sinkFile outputFile)
#else
    runResourceT $ sourceSocket s2 $$ sinkFile outputFile
#endif
    return ()
  where
    setup = do
#if MIN_VERSION_conduit(1,3,0)
        runResourceT $ runConduit (sourceFile inputFile .| sinkFile tempFile)
#else
        runResourceT $ sourceFile inputFile $$ sinkFile tempFile
#endif
        (s1,s2) <- sockpair
        ref <- newIORef (1 :: Int)
        tid <- forkOS (sf s1 ref `finally` sendEOF s1)
        return (s2,tid)
      where
        sf s1 ref
          | headers == [] = sendfile s1 tempFile range (hook ref)
          | otherwise     = sendfileWithHeader s1 tempFile range (hook ref) headers
        sendEOF = close
        hook ref = do
            n <- readIORef ref
            when (n == 10) $ setFileSize tempFile 900000
            writeIORef ref (n+1)
    teardown (s2,tid) = do
        close s2
        killThread tid
        removeFileIfExists tempFile
        removeFileIfExists outputFile
    inputFile = "test/inputFile"
    tempFile = "test/tempFile"
    outputFile = "test/outputFile"
    range = EntireFile

----------------------------------------------------------------

removeFileIfExists :: FilePath -> IO ()
removeFileIfExists file = do
    exist <- doesFileExist file
    when exist $ removeFile file

sinkAppendFile :: MonadResource m
                  => FilePath
#if MIN_VERSION_conduit(1,3,0)
                  -> ConduitT ByteString Void m ()
#else
                  -> Sink ByteString m ()
#endif
sinkAppendFile fp = sinkIOHandle (openBinaryFile fp AppendMode)

----------------------------------------------------------------

sockpair :: IO (Socket, Socket)
sockpair = withSystemTempFile "temp-for-pair" $ \file hdl -> do
    hClose hdl
    removeFile file
    listenSock <- socket AF_UNIX Stream defaultProtocol
    bind listenSock $ SockAddrUnix file
    listen listenSock 10
    clientSock <- socket AF_UNIX Stream defaultProtocol
    connect clientSock $ SockAddrUnix file
    (serverSock, _) <- accept listenSock
    close listenSock
    return (clientSock, serverSock)
