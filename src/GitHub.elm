module GitHub
    exposing
        ( APIError
        , Repo
        , Issue
        , IssueState(..)
        , IssueLabel
        , Comment
        , User
        , fetchOrgMembers
        , fetchOrgRepos
        , fetchRepoIssues
        , fetchIssue
        , fetchIssueComments
        , issueScore
        , reactionCodes
        , reactionScore
        )

import Date exposing (Date)
import Dict exposing (Dict)
import Http
import HttpBuilder
import Json.Decode
import Json.Decode.Extra exposing ((|:))
import Regex exposing (Regex)
import String
import Task exposing (Task)
import Pagination


type alias Token =
    String


type alias APIError =
    { message : String
    }



type alias Repo =
    { id : Int
    , url : String
    , owner : User
    , name : String
    , openIssues : Int
    }


type alias Issue =
    { repo : Repo
    , id : Int
    , createdAt : Date
    , updatedAt : Date
    , url : String
    , state : IssueState
    , isPullRequest : Bool
    , user : User
    , number : Int
    , title : String
    , commentCount : Int
    , reactions : Reactions
    , labels : List IssueLabel
    }


type alias IssueLabel =
    { name : String
    , color : String
    }


type IssueState
    = IssueStateOpen
    | IssueStateClosed


type alias Comment =
    { issue : Issue
    , id : Int
    , createdAt : Date
    , updatedAt : Date
    , url : String
    , user : User
    , reactions : Reactions
    }


type alias User =
    { id : Int
    , url : String
    , login : String
    , avatar : String
    }


type alias Reactions =
    { plusOne : Int
    , minusOne : Int
    , laugh : Int
    , confused : Int
    , heart : Int
    , hooray : Int
    }


reactionCodes : Reactions -> List ( String, Int )
reactionCodes reactions =
    [ ( "👍", reactions.plusOne )
    , ( "👎", reactions.minusOne )
    , ( "😄", reactions.laugh )
    , ( "😕", reactions.confused )
    , ( "🎉", reactions.heart )
    , ( "💖", reactions.hooray )
    ]


issueScore : Issue -> Int
issueScore { reactions, commentCount, isPullRequest } =
    reactionScore reactions
        + (2 * commentCount)
        + (if isPullRequest then
            1000
           else
            0
          )


reactionScore : Reactions -> Int
reactionScore reactions =
    List.sum
        [ 2 * reactions.plusOne
        , -2 * reactions.minusOne
        , 1 * reactions.laugh
        , -1 * reactions.confused
        , 3 * reactions.heart
        , 3 * reactions.hooray
        ]


auth : String -> List (String, String)
auth token =
    if token == "" then
        []
    else
        [ ("Authorization", "token " ++ token) ]

authHeaders : String -> List Http.Header
authHeaders = List.map (uncurry Http.header) << auth

fetchOrgMembers : Token -> String -> Task Http.Error (List User)
fetchOrgMembers token org =
    Pagination.fetchAll
        ("https://api.github.com/orgs/" ++ org ++ "/members?per_page=100")
        (authHeaders token)
        (rfc5988Strategy decodeUser)
        Nothing


fetchOrgRepos : Token -> String -> Task Http.Error (List Repo)
fetchOrgRepos token org =
    Pagination.fetchAll
        ("https://api.github.com/orgs/" ++ org ++ "/repos?per_page=100")
        (authHeaders token)
        (rfc5988Strategy decodeRepo)
        Nothing


fetchRepoIssues : Token -> Repo -> Task Http.Error (List Issue)
fetchRepoIssues token repo =
    if repo.openIssues == 0 then
        Task.succeed []
    else
        Pagination.fetchAll
            ("https://api.github.com/repos/" ++ repo.owner.login ++ "/" ++ repo.name ++ "/issues?per_page=100")
            (Http.header "Accept" "application/vnd.github.squirrel-girl-preview" :: authHeaders token)
            (rfc5988Strategy (decodeIssue repo))
            Nothing


fetchIssue : Token -> Repo -> Int -> Task Http.Error Issue
fetchIssue token repo number =
    HttpBuilder.get ("https://api.github.com/repos/" ++ repo.owner.login ++ "/" ++ repo.name ++ "/issues/" ++ toString number)
        |> HttpBuilder.withHeaders (auth token)
        |> HttpBuilder.withHeader "Accept" "application/vnd.github.squirrel-girl-preview"
        |> HttpBuilder.withExpect (Http.expectJson (decodeIssue repo))
        |> HttpBuilder.toTask


fetchIssueComments : Token -> Issue -> Task Http.Error (List Comment)
fetchIssueComments token issue =
    Pagination.fetchAll
        ("https://api.github.com/repos/" ++ issue.repo.owner.login ++ "/" ++ issue.repo.name ++ "/issues/" ++ toString issue.number ++ "/comments?per_page=100")
        (Http.header "Accept" "application/vnd.github.squirrel-girl-preview" :: authHeaders token)
        (rfc5988Strategy (decodeComment issue))
        Nothing


decodeError : Json.Decode.Decoder APIError
decodeError =
    Json.Decode.map APIError
        (Json.Decode.field "message" Json.Decode.string)


decodeRepo : Json.Decode.Decoder Repo
decodeRepo =
    Json.Decode.map5 Repo
        (Json.Decode.field "id" Json.Decode.int)
        (Json.Decode.field "html_url" Json.Decode.string)
        (Json.Decode.field "owner" decodeUser)
        (Json.Decode.field "name" Json.Decode.string)
        (Json.Decode.field "open_issues_count" Json.Decode.int)


decodeIssue : Repo -> Json.Decode.Decoder Issue
decodeIssue repo =
    Json.Decode.succeed (Issue repo)
        |: (Json.Decode.field "id" Json.Decode.int)
        |: (Json.Decode.field "created_at" Json.Decode.Extra.date)
        |: (Json.Decode.field "updated_at" Json.Decode.Extra.date)
        |: (Json.Decode.field "html_url" Json.Decode.string)
        |: (Json.Decode.field "state" decodeIssueState)
        |: (Json.Decode.map ((/=) Nothing) << Json.Decode.maybe <| Json.Decode.field "pull_request" Json.Decode.value)
        |: (Json.Decode.field "user" decodeUser)
        |: (Json.Decode.field "number" Json.Decode.int)
        |: (Json.Decode.field "title" Json.Decode.string)
        |: (Json.Decode.field "comments" <| excludeTracksuitComment (Json.Decode.int))
        |: (Json.Decode.field "reactions" decodeReactions)
        |: (Json.Decode.field "labels" <| Json.Decode.list decodeIssueLabel)


decodeIssueState : Json.Decode.Decoder IssueState
decodeIssueState =
    customDecoder Json.Decode.string <|
        \x ->
            case x of
                "open" ->
                    Ok IssueStateOpen

                "closed" ->
                    Ok IssueStateClosed

                _ ->
                    Err ("unknown issue state: " ++ x)


decodeIssueLabel : Json.Decode.Decoder IssueLabel
decodeIssueLabel =
    Json.Decode.map2 IssueLabel
        (Json.Decode.field "name" Json.Decode.string)
        (Json.Decode.field "color" Json.Decode.string)


decodeComment : Issue -> Json.Decode.Decoder Comment
decodeComment issue =
    Json.Decode.map6 (Comment issue)
        (Json.Decode.field "id" Json.Decode.int)
        (Json.Decode.field "created_at" Json.Decode.Extra.date)
        (Json.Decode.field "updated_at" Json.Decode.Extra.date)
        (Json.Decode.field "html_url" Json.Decode.string)
        (Json.Decode.field "user" decodeUser)
        (Json.Decode.field "reactions" decodeReactions)


decodeUser : Json.Decode.Decoder User
decodeUser =
    Json.Decode.map4 User
        (Json.Decode.field "id" Json.Decode.int)
        (Json.Decode.field "html_url" Json.Decode.string)
        (Json.Decode.field "login" Json.Decode.string)
        (Json.Decode.field "avatar_url" Json.Decode.string)


excludeTracksuitComment : Json.Decode.Decoder Int -> Json.Decode.Decoder Int
excludeTracksuitComment =
    Json.Decode.map (flip (-) 1)


decodeReactions : Json.Decode.Decoder Reactions
decodeReactions =
    Json.Decode.map6 Reactions
        (Json.Decode.field "+1" Json.Decode.int)
        (Json.Decode.field "-1" Json.Decode.int)
        (Json.Decode.field "laugh" Json.Decode.int)
        (Json.Decode.field "confused" Json.Decode.int)
        (Json.Decode.field "heart" Json.Decode.int)
        (Json.Decode.field "hooray" Json.Decode.int)


rfc5988Strategy : Json.Decode.Decoder a -> Pagination.Strategy Int a
rfc5988Strategy decode =
    { onPage = flip addParams
    , nextPage =
        parseLink nextRel
    , previousPage =
        parseLink previousRel
    , content =
        Json.Decode.list decode
    }


parseLink : String -> Http.Response a -> Maybe Int
parseLink rel response =
    Dict.get "Link" response.headers
        |> Maybe.andThen
            (\commaSeparatedCraziness ->
                let
                    headers =
                        String.split ", " commaSeparatedCraziness

                    parsed =
                        Dict.fromList <| List.filterMap parseLinkTuple headers
                in
                    Dict.get rel parsed |> Maybe.andThen parseParams
            )


previousRel : String
previousRel =
    "prev"


nextRel : String
nextRel =
    "next"


linkHeaderRegex : Regex
linkHeaderRegex =
    Regex.regex ("<([^>]+)>; rel=\"(" ++ previousRel ++ "|" ++ nextRel ++ ")\"")


parseLinkTuple : String -> Maybe ( String, String )
parseLinkTuple header =
    case Regex.find (Regex.AtMost 1) linkHeaderRegex header of
        [] ->
            Nothing

        { submatches } :: _ ->
            case submatches of
                (Just url) :: (Just rel) :: _ ->
                    Just ( rel, url )

                _ ->
                    Nothing


parseParams : String -> Maybe Int
parseParams =
    fromQuery << Tuple.second << extractQuery


addParams : String -> Int -> String
addParams url page =
    let
        ( baseURL, query ) =
            extractQuery url
    in
        setQuery baseURL (Dict.union query (toQuery page))


extractQuery : String -> ( String, Dict String String )
extractQuery url =
    case String.split "?" url of
        baseURL :: query :: _ ->
            ( baseURL, parseQuery query )

        _ ->
            ( url, Dict.empty )


setQuery : String -> Dict String String -> String
setQuery baseURL query =
    let
        params =
            String.join "&" <|
                List.map (\( k, v ) -> k ++ "=" ++ v) (Dict.toList query)
    in
        if params == "" then
            baseURL
        else
            baseURL ++ "?" ++ params


parseQuery : String -> Dict String String
parseQuery query =
    let
        parseParam p =
            case String.split "=" p of
                k :: vs ->
                    ( k, String.join "=" vs )

                [] ->
                    ( "", "" )
    in
        Dict.fromList <|
            List.map parseParam <|
                String.split "&" query


fromQuery : Dict String String -> Maybe Int
fromQuery query =
    let
        num =
            Maybe.withDefault 1 (
                Dict.get "page" query
                    |> Maybe.andThen parseNum
            )
    in
        Just num


toQuery : Int -> Dict String String
toQuery page =
    Dict.singleton "page" (toString page)


parseNum : String -> Maybe Int
parseNum =
    Result.toMaybe << String.toInt


customDecoder : Json.Decode.Decoder b -> (b -> Result String a) -> Json.Decode.Decoder a
customDecoder decoder toResult =
    Json.Decode.andThen
        (\a ->
            case toResult a of
                Ok b ->
                    Json.Decode.succeed b

                Err err ->
                    Json.Decode.fail err
        )
        decoder
