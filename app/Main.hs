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
import           Sockets.Connections            ( initializeConnectionMap )

main :: IO ()
main = do
    wsConnMap <- initializeConnectionMap
    withRedisSubs
        ( chatInterServerMessageHandler wsConnMap
        : pingInterServerMessageHandlers wsConnMap
        )
        (runEnv 9001 . logStdoutDev . app wsConnMap)
