module Main where

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
    wsController <- initializeWebsocketsController
    withRedisSubs
        ( chatInterServerMessageHandler wsController
        : pingInterServerMessageHandlers wsController
        )
        (runEnv 9001 . logStdoutDev . app wsController)
