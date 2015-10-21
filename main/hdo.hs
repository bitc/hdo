{-# LANGUAGE DoAndIfThenElse       #-}
{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE OverloadedStrings     #-}
{-# LANGUAGE RecordWildCards       #-}
{-# LANGUAGE ScopedTypeVariables   #-}
module Main where

import           Control.Exception      (catch, throw)
import           Control.Monad.IO.Class (MonadIO (..))
import           Data.Maybe
import           Prelude                as P
import           System.Console.GetOpt
import           System.Environment
import           System.IO
import           System.IO.Error        (isDoesNotExistError)

import           Network.DO.Commands
import           Network.DO.Names
import           Network.DO.Net
import           Network.DO.Pairing
import           Network.DO.Pretty      (outputResult)
import           Network.DO.Types       as DO
import           Network.REST

generalOptions :: [OptDescr (ToolConfiguration -> ToolConfiguration)]
generalOptions = [ Option ['t'] ["auth-token"]
                   (ReqArg ( \ t config -> config { authToken = Just t}) "STRING")
                   "Authentication token used for communicating with server (default: <extracted from $AUTH_TOKEN environment)"
                 , Option ['q'] ["quiet"]
                   (NoArg ( \ config -> config { quiet = True}))
                   "Don't send notifications of operations to Slack (default: False)"
                 ]

createDropletOptions :: [OptDescr (BoxConfiguration -> BoxConfiguration)]
createDropletOptions = [ Option ['n'] ["name"]
                         (ReqArg ( \ n config -> config { configName = n }) "STRING")
                         "name of the box to create (default: <randomly generated name>)"
                       , Option ['r'] ["region"]
                         (ReqArg ( \ r config -> config { boxRegion = RegionSlug r}) "REGION")
                         "region where the instance is to be deployed (default: 'ams2')"
                       , Option ['s'] ["size"]
                         (ReqArg ( \ s config -> config { size = read s}) "SIZE")
                         "size of instance to deploy (default: '4gb')"
                       , Option ['i'] ["image-slug"]
                         (ReqArg ( \ i config -> config { configImageSlug = i}) "IMAGE")
                         "slug of image to deploy (default: 'ubuntu-14-04-x64')"
                       , Option ['k'] ["key"]
                         (ReqArg ( \ k config -> config { keys = read k ++ keys config}) "[KEY1,..]")
                         "add a key to access box (default: '[]')"
                       ]

getAuthFromEnv :: IO (Maybe AuthToken)
getAuthFromEnv = (Just `fmap` getEnv "AUTH_TOKEN") `catch` (\ (e :: IOError) -> if isDoesNotExistError e then return Nothing else throw e)

getSlackUriFromEnv :: IO (Maybe URI)
getSlackUriFromEnv = (Just `fmap` getEnv "SLACK_URI") `catch` (\ (e :: IOError) -> if isDoesNotExistError e then return Nothing else throw e)

defaultBox :: IO BoxConfiguration
defaultBox = do
  name <- generateName
  return $ BoxConfiguration name (RegionSlug "ams2") G4 defaultImage [429079]

defaultTool :: IO ToolConfiguration
defaultTool = do
  uri <- getSlackUriFromEnv
  tok <- getAuthFromEnv
  return $ Tool uri tok False

usage :: String
usage = usageInfo (banner ++ "\n" ++ usageInfo "General options:" generalOptions ++ "\nCommands options:") createDropletOptions
  where
    banner = "Usage: toolbox [OPTIONS..] COMMAND [CMD OPTIONS...]"

parseOptions  :: [String] -> IO (ToolConfiguration, [String])
parseOptions args = do
  d <- defaultTool
  case getOpt RequireOrder generalOptions args of
   (opts, coms, []) ->  return ((foldl (flip P.id) d opts), coms)
   (_,_,errs)       ->  ioError(userError (concat errs  ++ usage))


parseCommandOptions :: (MonadIO m) => [String] -> DOT m ()
parseCommandOptions ("droplets":"create":args) = do
  b <- liftIO defaultBox
  case getOpt Permute createDropletOptions args of
   (c,[],[])  -> createDroplet (foldl (flip P.id) b c) >>= outputResult
   (_,_,errs) -> liftIO $ ioError (userError (concat errs  ++ usage))
parseCommandOptions ("droplets":"destroy":dropletId:[]) = destroyDroplet (P.read dropletId)  >>= outputResult
parseCommandOptions ("droplets":"list":_)               = listDroplets  >>= outputResult
parseCommandOptions ("droplets":"power_off":dropletId:[])
                                                         = dropletAction (P.read dropletId) DoPowerOff >>= outputResult
parseCommandOptions ("droplets":"power_on":dropletId:[])
                                                         = dropletAction (P.read dropletId) DoPowerOn >>= outputResult
parseCommandOptions ("droplets":"snapshot":dropletId:snapshotName:[])
                                                         = dropletAction (P.read dropletId) (CreateSnapshot snapshotName) >>= outputResult
parseCommandOptions ("droplets":"action":dropletId:actionId:[])
                                                         = getAction (P.read dropletId)  (P.read actionId) >>= outputResult
parseCommandOptions ("images":"list":_)                 = listImages >>= outputResult
parseCommandOptions ("keys":"list":_)                    = listKeys >>= outputResult
parseCommandOptions ("sizes":"list":_)                   = listSizes >>= outputResult
parseCommandOptions e                                    = fail $ "I don't know how to interpret commands " ++ unwords e

main :: IO ()
main = do
  hSetBuffering stdin NoBuffering
  args <- getArgs
  (opts, cmds) <- parseOptions args
  runWreq $ pairEffectM (\ _ b -> return b) (mkDOClient opts) (parseCommandOptions cmds)

