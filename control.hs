{-# LANGUAGE OverloadedStrings #-}
module Main where

import           Control.Applicative
import           Data.Maybe (isNothing, fromJust)
import qualified Data.MessagePack as MP
import qualified Data.Text as T
import qualified Data.Text.IO as TIO
import Data.UUID.V4 (nextRandom)
import Data.UUID (toString)
import           Data.Yaml.Config (load, subconfig, lookupDefault)
import qualified Data.Yaml.Config as YC
import           Network.AMQP
import           System.Environment (getArgs)

import Master
import Types

main :: IO ()
main = do
  (configFile:args) <- getArgs
  config <- load configFile
  masterConfig <- subconfig "master" config
  managerConfig <- subconfig "manager" config
  (conn, chan) <- connection masterConfig
  let cname = lookupDefault "command" "Command" config
  declareQueue chan newQueue { queueName = cname }
  (callback,_,_) <- declareQueue chan newQueue { queueExclusive = True }
  corrid <- T.pack . toString <$> nextRandom
  publishMsg chan "" cname newMsg { msgBody = MP.pack $ args
                                  , msgReplyTo = Just callback
                                  , msgCorrelationID = Just corrid
                                  }
  consumeRes chan callback
  closeConnection conn
  where consumeRes chan callback = do
          Just (msg, env) <- getMsgWait chan callback
          ackEnv env
          TIO.putStrLn . MP.unpack $ msgBody msg
        getMsgWait chan callback = do
          x <- getMsg chan Ack callback
          if isNothing x
            then getMsgWait chan callback
            else return x
