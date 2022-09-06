module Main where

import           Network.Wai.Handler.Warp       ( runEnv )

import           HttpServer
import           ISCB

main :: IO ()
main = withRedisSubs (runEnv 9001 . app)
