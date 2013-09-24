{-# LANGUAGE OverloadedStrings #-}
module Main where

import           Control.Applicative
import           Control.Concurrent (forkIO, ThreadId)
import qualified Control.Exception as CE
import           Control.Lens
import           Data.IORef (newIORef, readIORef, modifyIORef, IORef)
import qualified Data.Map as M
import           Data.Maybe (fromJust)
import qualified Data.MessagePack as MP
import qualified Data.Text as T
import qualified Data.Text.IO as TIO
import           Data.UUID (toString)
import           Data.UUID.V4 (nextRandom)
import           Data.Yaml.Config (load, subconfig, lookupDefault)
import qualified Data.Yaml.Config as YC
import           Network.AMQP
import           System.Environment (getArgs)

import Master
import Types

type Target   = T.Text
type Packages = T.Text
data Status   = New
              | Building
              | Done T.Text
              deriving (Show, Read)
type Result   = T.Text
type Job = (UUID, Target, Packages, Status)
type Jobs = M.Map UUID Job

main :: IO ()
main = do
  (configFile:_) <- getArgs
  config <- load configFile
  masterConfig <- subconfig "master" config
  managerConfig <- subconfig "manager" config
  (conn, chan) <- connection masterConfig
  stateFile <- YC.lookup "state-file" managerConfig
  jobs <- CE.catch (read <$> readFile stateFile)
          (\e -> do
              putStrLn $ show (e :: CE.IOException)
              return M.empty)
  putStrLn "Waiting for a command"
  CE.bracket (newIORef jobs)
    (close stateFile conn)
    (mainwork chan config)
  where close file conn ref = do
          closeConnection conn
          newstate <- readIORef ref
          writeFile file $ show newstate
        mainwork chan config ref = do
          declareQueue chan newQueue { queueName = cname }
          declareQueue chan newQueue { queueName = rname }
          consumeMsgs chan cname Ack $ commandCallback bname ref
          consumeMsgs chan rname Ack $ buildResultCallback ref
          getLine
          return ()
            where cname = lookupDefault "command" "Command" config
                  bname = lookupDefault "builder" "Builder" config
                  rname = T.concat [ bname, "Result" ]

commandCallback :: T.Text -> IORef Jobs -> (Message, Envelope) -> IO ()
commandCallback builderName ref (msg, env) = do
  putStr "Recieved: "
  TIO.putStrLn $ T.unwords command
  respond command
  ackEnv env
  putStrLn "\tdone"
  where chan = envChannel env
        command = MP.unpack $ msgBody msg
        respond ("build":target:pkgs) = do
          let arg = T.unwords pkgs
          uuid <- T.pack . toString <$> nextRandom
          modifyIORef ref (M.insert uuid (uuid, target, arg, New))
          forkIO $ publishMsg chan builderName target
            newMsg { msgBody = MP.pack (uuid, arg) }
          sendReply "Added";
        respond ("jobs":_) = do
          jobs <- readIORef ref
          sendReply . T.unlines . map showJob $ M.elems jobs
        respond ("result":jobid:_) = do
          jobs <- readIORef ref
          respondResult $ M.lookup jobid jobs
        respond _ = sendReply "Not implemented."
        respondResult (Just (_,_,_,Done x)) = sendReply x
        respondResult (Just _) = sendReply "Not yet done."
        respondResult Nothing = sendReply "No such job."
        showJob (uuid, target, pkgs, stat) = T.concat [ uuid, " "
                                                      , showStat stat
                                                      , target, "\t"
                                                      , pkgs
                                                      ]
        showStat New      = "New      "
        showStat Building = "Building "
        showStat (Done _) = "Done     "
        sendReply :: T.Text -> IO ThreadId
        sendReply result = forkIO $ publishMsg chan "" key
                           newMsg { msgBody = MP.pack result
                                  , msgCorrelationID = msgCorrelationID msg
                                  }
        key = fromJust $ msgReplyTo msg

buildResultCallback :: IORef Jobs -> (Message, Envelope) -> IO ()
buildResultCallback ref (msg, env) = do
  updateState res
  ackEnv env
  where res = MP.unpack $ msgBody msg
        updateState (BuildStart uuid) = modifyIORef ref $ M.adjust (set _4 Building) uuid
        updateState (BuildFinished uuid result) = modifyIORef ref $ M.adjust (set _4 (Done result)) uuid
