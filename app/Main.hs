module Main where

import           Control.Monad                  ( void )
import           Database.Redis                 ( addChannels
                                                , newPubSubController
                                                )
import           Network.Wai.Handler.Warp       ( runEnv )
import           Network.Wai.Middleware.RequestLogger
                                                ( logStdoutDev )

import           Chat                           ( chatInterServerMessageHandler
                                                )
import           HttpServer                     ( app )
import           ISCB                           ( withRedisSubs )
import           Ping                           ( pingInterServerMessageHandlers
                                                )
import           Sockets.Controller             ( initializeWebsocketsController
                                                )

main :: IO ()
main = do
    pubSubController <- newPubSubController [] []
    putStrLn "PubSub Initialized"
    wsController <- initializeWebsocketsController pubSubController
    putStrLn "WS Initialized"
    void $ addChannels
        pubSubController
        ( chatInterServerMessageHandler wsController
        : pingInterServerMessageHandlers wsController
        )
        []
    putStrLn "Added Initial PubSub Handlers"
    withRedisSubs pubSubController
                  (runEnv 9001 . logStdoutDev . app wsController)
