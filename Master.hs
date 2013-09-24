{-# LANGUAGE OverloadedStrings #-}
module Master ( connection
              )
       where

import           Data.Yaml.Config (Config, lookupDefault)
import qualified Data.Yaml.Config as YC
import           Network.AMQP

connection :: Config -> IO (Connection, Channel)
connection config = do
  server <- YC.lookup "address" config
  let vhost  = lookupDefault "vhost" "/" config
      user   = lookupDefault "user" "guest" config
      pass   = lookupDefault "password" "guest" config
  conn <- openConnection server vhost user pass
  chan <- openChannel conn
  return (conn, chan)

