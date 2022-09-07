module Main where

import           Network.Wai.Handler.Warp       ( runEnv )
import           Network.Wai.Middleware.RequestLogger
                                                ( logStdoutDev )

import           HttpServer
import           ISCB

main :: IO ()
main = withRedisSubs (runEnv 9001 . logStdoutDev . app)
