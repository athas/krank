{-# LANGUAGE ApplicativeDo #-}
{-# LANGUAGE DataKinds #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE QuasiQuotes #-}
{-# LANGUAGE ScopedTypeVariables #-}

module Krank.Checkers.IssueTracker (
  GitIssue(..)
  , GitServer(..)
  , checkFile
  , checkText
  , extractIssues
  , githubRE
  , gitlabRE
  , gitRepoRE
  ) where

import Control.Applicative ((*>), optional)
import Control.Exception (catch)
import Data.Aeson (Value, (.:))
import qualified Data.Aeson.Types as AesonT
import qualified Data.ByteString.UTF8 as BSU
import Data.Char (isDigit)
import Data.Maybe (fromMaybe)
import Data.Text (Text, pack)
import qualified Network.HTTP.Req as Req
import PyF (fmt)
import System.IO (readFile)
import Text.Regex.Applicative ((=~), RE(), few, psym, some, string)

import Krank.Checkers.Common
import Krank.Types

data GitServer = Github | Gitlab deriving (Eq, Show)

data IssueStatus = Open | Closed deriving (Eq, Show)

data GitIssue = GitIssue {
  server :: GitServer,
  owner :: Text,
  repo :: Text,
  issueNum :: Int
} deriving (Eq, Show)

data GitIssueWithStatus = GitIssueWithStatus {
  gitIssue :: GitIssue,
  issueStatus :: IssueStatus
} deriving (Eq, Show)

serverDomain :: GitServer
             -> String
serverDomain Github = "github.com"
serverDomain Gitlab = "gitlab.com"

githubRE :: RE Char GitIssue
githubRE = gitRepoRE Github

gitlabRE :: RE Char GitIssue
gitlabRE = gitRepoRE Gitlab

gitRepoRE :: GitServer
          -> RE Char GitIssue
gitRepoRE gitServer = do
  optional ("http" *> optional "s" *> "://")
  optional "www."
  string (serverDomain gitServer)
  "/"
  repoOwner <- few (psym ('/' /=))
  "/"
  repoName <- few (psym ('/' /=))
  "/"
  "issues/"
  issueNumStr <- some (psym isDigit)
  -- Note that read is safe because of the regex parsing
  return $ GitIssue gitServer (pack repoOwner) (pack repoName) (read issueNumStr)

extractIssues :: String
              -> [GitIssue]
extractIssues toCheck =
  concat matches
    where
      patterns = [githubRE, gitlabRE]
      mMatches = (=~) toCheck . multiple <$> patterns
      matches = fromMaybe [] <$> mMatches

-- Supports only github for the moment
issueUrl :: GitIssue
         -> Req.Url 'Req.Https
issueUrl issue = case server issue of
  Github -> Req.https "api.github.com" Req./: "repos" Req./: owner issue Req./: repo issue Req./: "issues" Req./: (pack . show $ issueNum issue)
  Gitlab -> Req.https "google.com"

-- try Issue can fail, on non-2xx HTTP response
tryRestIssue :: Req.Url 'Req.Https
             -> GithubKey
             -> IO Value
tryRestIssue url (GithubKey mGithubKey) =
  Req.runReq Req.defaultHttpConfig $ do
    r <- Req.req Req.GET url Req.NoReqBody Req.jsonResponse (
      Req.header "User-Agent" "krank"
      <> authHeaders)
    pure $ Req.responseBody r

  where
    authHeaders = case mGithubKey of
      Just token -> Req.oAuth2Token (BSU.fromString token)
      Nothing -> mempty

httpExcHandler :: Req.Url 'Req.Https
               -> Req.HttpException
               -> IO Value
httpExcHandler url _ = pure . AesonT.object $ [("error", AesonT.String . pack . show $ url)]

restIssue :: GithubKey
             -> Req.Url 'Req.Https
             -> IO Value
restIssue mGithubKey url = catch (tryRestIssue url mGithubKey) (httpExcHandler url)

statusParser :: Value
            -> Either Text IssueStatus
statusParser (AesonT.Object o) = do
  let state :: AesonT.Result String = AesonT.parse (.: "state") o
  readState state
    where
      readState (AesonT.Success status) = case status of
        "closed" -> Right Closed
        "open"   -> Right Open
        _        -> Left [fmt|Could not parse status '{status}'|]
      readState (AesonT.Error _) = Left $ errorParser o
statusParser _ = Left "invalid JSON"

errorParser :: AesonT.Object
            -> Text
errorParser o = do
  let err = AesonT.parse (.: "error") o
  readErr err
    where
      readErr (AesonT.Success errText) = pack errText
      readErr (AesonT.Error _) = "invalid JSON"

gitIssuesWithStatus :: [GitIssue]
                    -> GithubKey
                    -> IO [Either Text GitIssueWithStatus]
gitIssuesWithStatus issues mGithubKey = do
  let urls = issueUrl <$> issues
  statuses <- mapM (restIssue mGithubKey) urls
  pure $ zipWith f issues (fmap statusParser statuses)
    where
      f _ (Left err) = Left err
      f issue (Right is) = Right $ GitIssueWithStatus issue is

issueTrackerChecker :: Text
issueTrackerChecker = "GIT Issue Tracker"

issueToLevel :: GitIssueWithStatus
             -> ViolationLevel
issueToLevel i = case issueStatus i of
  Open   -> Info
  Closed -> Error

issueToSnippet :: GitIssueWithStatus
               -> Text
issueToSnippet i = [fmt|{owner issue}/{repo issue}|]
  where
    issue = gitIssue i

issueToMessage :: GitIssueWithStatus
               -> Text
issueToMessage i = case issueStatus i of
  Open   -> [fmt|issue #{issueNum issue} still Open|]
  Closed -> [fmt|issue #{issueNum issue} is now Closed|]
  where
    issue = gitIssue i

checkText :: String
          -> GithubKey
          -> IO [Violation]
checkText t mGithubKey = do
  let issues = extractIssues t
  issuesWithStatus <- gitIssuesWithStatus issues mGithubKey
  pure $ fmap f issuesWithStatus
    where
      f (Left err) = Violation issueTrackerChecker Warning "Url could not be reached" err
      f (Right issue) = Violation issueTrackerChecker (issueToLevel issue) (issueToSnippet issue) (issueToMessage issue)

checkFile :: FilePath
      -> IO [Violation]
checkFile file = do
  content <- readFile file
  checkText content (GithubKey Nothing)
