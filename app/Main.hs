module Main where

import           Network.Wai.Handler.Warp       ( runEnv )
import           Network.Wai.Middleware.RequestLogger
                                                ( logStdoutDev )

import           HttpServer                     ( app )
import           ISCB                           ( withRedisSubs )
import           Sockets                        ( initializeConnectionMap )

main :: IO ()
main = do
    wsConnMap <- initializeConnectionMap
    withRedisSubs (runEnv 9001 . logStdoutDev . app wsConnMap)
