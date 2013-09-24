{-# LANGUAGE OverloadedStrings #-}
module Main where

import           Control.Concurrent (forkIO)
import qualified Control.Exception as CE
import           Data.Conduit
import qualified Data.Conduit.List as CL
import           Data.Conduit.Process (sourceCmd)
import           Data.Conduit.Text (decode, utf8)
import qualified Data.MessagePack as MP
import qualified Data.Text as T
import qualified Data.Text.IO as TIO
import qualified Data.Text.Lazy as TL
import           Data.Yaml.Config (load, subconfig, Config, lookupDefault)
import qualified Data.Yaml.Config as YC
import           Network.AMQP
import           System.Environment (getArgs)

import Types
import Master

main :: IO ()
main = do
  (configFile:_) <- getArgs
  config <- load configFile
  masterConfig <- subconfig "master" config
  builderConfig <- subconfig "builder" config  
  (conn, chan) <- connection masterConfig

  let name = lookupDefault "queue" "Builder" builderConfig
  target <- YC.lookup "target" builderConfig
  declareExchange chan newExchange { exchangeName = name
                                   , exchangeType = "topic"
                                   }
  (qname,_,_) <- declareQueue chan newQueue { queueExclusive = True }
  bindQueue chan qname name $ T.pack target
  qos chan 0 1
  putStrLn $ "Waiting a package for " ++ target
  consumeMsgs chan qname Ack (myCallback builderConfig)
  getLine
  closeConnection conn

myCallback :: Config -> (Message, Envelope) -> IO ()
myCallback config (msg, env) = do
  putStr "Building "; TIO.putStrLn pkg
  reply $ BuildStart uuid
  base <- YC.lookup "command" config
  output <- runResourceT $
            sourceCmd (command base)
            $= decode utf8 $$ CL.consume
  putStr "Done "; TIO.putStrLn pkg
  reply . BuildFinished uuid . TL.toStrict $ TL.fromChunks output
  ackEnv env
  where chan = envChannel env
        key = T.concat [ lookupDefault "builder" "Builder" config
                       , "Result" ]
        exchange = ""
        replyMsg body = newMsg { msgBody = MP.pack body }
        reply body = forkIO . publishMsg chan exchange key $ replyMsg body
        command base = subst base
        uuid :: UUID
        pkg :: T.Text
        (uuid, pkg) = MP.unpack $ msgBody msg
        subst = T.unpack . T.unwords . map f . T.words
        f s
          | s == "%s" = pkg
          | otherwise = s
