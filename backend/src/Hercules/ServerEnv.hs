{-# LANGUAGE FlexibleContexts           #-}
{-# LANGUAGE GeneralizedNewtypeDeriving #-}
{-# LANGUAGE RecordWildCards            #-}
{-# LANGUAGE StrictData                 #-}

module Hercules.ServerEnv
  ( Env(..)
  , App(..)
  , runApp
  , newEnv
  , runQueryWithConnection
  , withHttpManager
  , getAuthenticator
  , makeUserJWT
  ) where

import Control.Monad.Except.Extra
import Control.Monad.Log
import Control.Monad.Reader
import Crypto.JOSE.Error
import Data.ByteString.Lazy            (toStrict)
import Data.List                       (find)
import Data.Maybe                      (fromMaybe)
import Data.Pool
import Data.Profunctor.Product.Default (Default)
import Data.String                     (fromString)
import Data.Text.Encoding              (encodeUtf8)
import Data.Time.Format
import Database.PostgreSQL.Simple      (Connection, close, connectPostgreSQL)
import Network.HTTP.Client             as HTTP
import Network.HTTP.Client.TLS
import Opaleye                         (Query, QueryRunner, Unpackspec,
                                        runQuery, showSql)
import Servant                         (ServantErr)
import Servant.Auth.Server             (JWTSettings, defaultJWTSettings,
                                        generateKey, makeJWT)

import Hercules.Config
import Hercules.Log
import Hercules.OAuth.Types (AuthenticatorName, OAuth2Authenticator,
                             PackedJWT (..), authenticatorName)
import Hercules.OAuth.User

{-# ANN module "HLint: ignore Avoid lambda" #-}

data Env = Env { envConnectionPool :: Pool Connection
               , envHttpManager    :: HTTP.Manager
               , envAuthenticators :: [OAuth2Authenticator App]
               , envJWTSettings    :: JWTSettings
               }

newtype App a = App
  { unApp :: ReaderT Env (ExceptT ServantErr (LogM (WithSeverity LogMessage) IO)) a
  }
  deriving ( Functor
           , Applicative
           , Monad
           , MonadError ServantErr
           , MonadIO
           , MonadLog (WithSeverity LogMessage)
           , MonadReader Env
           )

-- | Perform an action with a PostgreSQL connection and return the result
withConnection :: (Connection -> IO a) -> App a
withConnection f = do
  connectionPool <- asks envConnectionPool
  liftIO $ withResource connectionPool f

withHttpManager :: (HTTP.Manager -> IO a) -> App a
withHttpManager f = do
  manager <- asks envHttpManager
  liftIO $ f manager

getAuthenticator :: AuthenticatorName -> App (Maybe (OAuth2Authenticator App))
getAuthenticator name =
  find ((== name) . authenticatorName) <$> asks envAuthenticators

makeUserJWT :: User -> App (Either Error PackedJWT)
makeUserJWT user = do
  jwtSettings <- asks envJWTSettings
  liftIO $ fmap (PackedJWT . toStrict) <$> makeJWT user jwtSettings Nothing

-- | Evaluate a query in an 'App' value
runQueryWithConnection
  :: Default QueryRunner columns haskells
  => Default Unpackspec columns columns
  => Query columns -> App [haskells]
runQueryWithConnection q = do
  logQuery q
  withConnection (\c -> runQuery c q)

logQuery
  :: Default Unpackspec columns columns
  => Query columns
  -> App ()
logQuery q =
  let s = fromMaybe "Empty query" $ showSql q
  in logDebug (fromString s)

runApp :: Env -> App a -> ExceptT ServantErr IO a
runApp env = mapExceptT runLog
           . flip runReaderT env
           . unApp
  where
    runLog :: LogM (WithSeverity LogMessage) IO a -> IO a
    runLog = (`runLoggingT` printMessage) . mapLogMessageM timestamp
    printMessage :: WithTimestamp (WithSeverity LogMessage) -> IO ()
    printMessage = print . renderWithTimestamp renderTime (renderWithSeverity render)
    renderTime = formatTime defaultTimeLocale "%b %_d %H:%M:%S"

newEnv :: MonadIO m => Config -> [OAuth2Authenticator App] -> m Env
newEnv Config{..} authenticators = liftIO $ do
  connection <- createPool
    (connectPostgreSQL (encodeUtf8 configConnectionString))
    close
    4 10 4
  httpManager <- newManager tlsManagerSettings
  key <- liftIO generateKey
  let jwtSettings = defaultJWTSettings key
  pure $ Env
    connection
    httpManager
    authenticators
    jwtSettings
