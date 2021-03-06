module Job.Job exposing
    ( Flags
    , Model
    , changeToJob
    , getUpdateMessage
    , handleCallback
    , init
    , subscriptions
    , update
    , view
    )

import Build.Styles as Styles
import BuildDuration
import Callback exposing (Callback(..))
import Colors
import Concourse
import Concourse.BuildStatus
import Concourse.Pagination
    exposing
        ( Page
        , Paginated
        , Pagination
        , chevron
        , chevronContainer
        )
import Dict exposing (Dict)
import DictView
import Effects exposing (Effect(..))
import Html exposing (Html)
import Html.Attributes
    exposing
        ( attribute
        , class
        , disabled
        , href
        , id
        , style
        )
import Html.Events
    exposing
        ( onClick
        , onMouseEnter
        , onMouseLeave
        )
import Html.Styled as HS
import Http
import Job.Msgs exposing (Hoverable(..), Msg(..))
import LoadingIndicator
import RemoteData exposing (WebData)
import Routes
import StrictEvents exposing (onLeftClick)
import Subscription exposing (Subscription(..))
import Time exposing (Time)
import TopBar.Model
import TopBar.Styles
import TopBar.TopBar as TopBar
import UpdateMsg exposing (UpdateMsg)
import UserState exposing (UserState)


type alias Model =
    { jobIdentifier : Concourse.JobIdentifier
    , job : WebData Concourse.Job
    , pausedChanging : Bool
    , buildsWithResources : Paginated BuildWithResources
    , currentPage : Maybe Page
    , now : Time
    , csrfToken : String
    , hovered : Hoverable
    , topBar : TopBar.Model.Model
    }


type alias BuildWithResources =
    { build : Concourse.Build
    , resources : Maybe Concourse.BuildResources
    }


jobBuildsPerPage : Int
jobBuildsPerPage =
    100


type alias Flags =
    { jobId : Concourse.JobIdentifier
    , paging : Maybe Page
    , csrfToken : String
    }


init : Flags -> ( Model, List Effect )
init flags =
    let
        ( topBar, topBarEffects ) =
            TopBar.init { route = Routes.Job { id = flags.jobId, page = flags.paging } }

        model =
            { jobIdentifier = flags.jobId
            , job = RemoteData.NotAsked
            , pausedChanging = False
            , buildsWithResources =
                { content = []
                , pagination =
                    { previousPage = Nothing
                    , nextPage = Nothing
                    }
                }
            , now = 0
            , csrfToken = flags.csrfToken
            , currentPage = flags.paging
            , hovered = None
            , topBar = topBar
            }
    in
    ( model
    , [ FetchJob flags.jobId
      , FetchJobBuilds flags.jobId flags.paging
      , GetCurrentTime
      ]
        ++ topBarEffects
    )


changeToJob : Flags -> Model -> ( Model, List Effect )
changeToJob flags model =
    ( { model
        | currentPage = flags.paging
        , buildsWithResources =
            { content = []
            , pagination =
                { previousPage = Nothing
                , nextPage = Nothing
                }
            }
      }
    , [ FetchJobBuilds model.jobIdentifier flags.paging ]
    )


getUpdateMessage : Model -> UpdateMsg
getUpdateMessage model =
    case model.job of
        RemoteData.Failure _ ->
            UpdateMsg.NotFound

        _ ->
            UpdateMsg.AOK


handleCallback : Callback -> Model -> ( Model, List Effect )
handleCallback msg model =
    let
        ( newTopBar, topBarEffects ) =
            TopBar.handleCallback msg model.topBar

        ( newModel, jobsEffects ) =
            handleCallbackWithoutTopBar msg model
    in
    ( { newModel | topBar = newTopBar }
    , topBarEffects ++ jobsEffects
    )


handleCallbackWithoutTopBar : Callback -> Model -> ( Model, List Effect )
handleCallbackWithoutTopBar callback model =
    case callback of
        BuildTriggered (Ok build) ->
            ( model
            , case build.job of
                Nothing ->
                    []

                Just job ->
                    [ NavigateTo <|
                        Routes.toString <|
                            Routes.Build
                                { id =
                                    { teamName = job.teamName
                                    , pipelineName = job.pipelineName
                                    , jobName = job.jobName
                                    , buildName = build.name
                                    }
                                , highlight = Routes.HighlightNothing
                                }
                    ]
            )

        JobBuildsFetched (Ok builds) ->
            handleJobBuildsFetched builds model

        JobFetched (Ok job) ->
            ( { model | job = RemoteData.Success job }
            , [ SetTitle <| job.name ++ " - " ]
            )

        JobFetched (Err err) ->
            case err of
                Http.BadStatus { status } ->
                    if status.code == 404 then
                        ( { model | job = RemoteData.Failure err }, [] )

                    else
                        ( model, redirectToLoginIfNecessary err )

                _ ->
                    ( model, [] )

        BuildResourcesFetched (Ok ( id, buildResources )) ->
            case model.buildsWithResources.content of
                [] ->
                    ( model, [] )

                anyList ->
                    let
                        transformer bwr =
                            if bwr.build.id == id then
                                { bwr | resources = Just buildResources }

                            else
                                bwr

                        bwrs =
                            model.buildsWithResources
                    in
                    ( { model
                        | buildsWithResources =
                            { bwrs
                                | content = List.map transformer anyList
                            }
                      }
                    , []
                    )

        BuildResourcesFetched (Err err) ->
            ( model, [] )

        PausedToggled (Ok ()) ->
            ( { model | pausedChanging = False }, [] )

        GotCurrentTime now ->
            ( { model | now = now }, [] )

        _ ->
            ( model, [] )


update : Msg -> Model -> ( Model, List Effect )
update action model =
    case action of
        TriggerBuild ->
            ( model, [ DoTriggerBuild model.jobIdentifier model.csrfToken ] )

        TogglePaused ->
            case model.job |> RemoteData.toMaybe of
                Nothing ->
                    ( model, [] )

                Just j ->
                    ( { model
                        | pausedChanging = True
                        , job = RemoteData.Success { j | paused = not j.paused }
                      }
                    , [ if j.paused then
                            UnpauseJob model.jobIdentifier model.csrfToken

                        else
                            PauseJob model.jobIdentifier model.csrfToken
                      ]
                    )

        NavTo route ->
            ( model, [ NavigateTo <| Routes.toString route ] )

        SubscriptionTick time ->
            ( model
            , [ FetchJobBuilds model.jobIdentifier model.currentPage
              , FetchJob model.jobIdentifier
              ]
            )

        Hover hoverable ->
            ( { model | hovered = hoverable }, [] )

        ClockTick now ->
            ( { model | now = now }, [] )

        FromTopBar m ->
            let
                ( newTopBar, topBarEffects ) =
                    TopBar.update m model.topBar
            in
            ( { model | topBar = newTopBar }, topBarEffects )


redirectToLoginIfNecessary : Http.Error -> List Effect
redirectToLoginIfNecessary err =
    case err of
        Http.BadStatus { status } ->
            if status.code == 401 then
                [ RedirectToLogin ]

            else
                []

        _ ->
            []


permalink : List Concourse.Build -> Page
permalink builds =
    case List.head builds of
        Nothing ->
            { direction = Concourse.Pagination.Since 0
            , limit = jobBuildsPerPage
            }

        Just build ->
            { direction = Concourse.Pagination.Since (build.id + 1)
            , limit = List.length builds
            }


paginatedMap : (a -> b) -> Paginated a -> Paginated b
paginatedMap promoter pagA =
    { content =
        List.map promoter pagA.content
    , pagination = pagA.pagination
    }


setResourcesToOld : Maybe BuildWithResources -> BuildWithResources -> BuildWithResources
setResourcesToOld existingBuildWithResource newBwr =
    case existingBuildWithResource of
        Nothing ->
            newBwr

        Just buildWithResources ->
            { newBwr
                | resources = buildWithResources.resources
            }


existingBuild : Concourse.Build -> BuildWithResources -> Bool
existingBuild build buildWithResources =
    build == buildWithResources.build


promoteBuild : Model -> Concourse.Build -> BuildWithResources
promoteBuild model build =
    let
        newBwr =
            { build = build
            , resources = Nothing
            }

        existingBuildWithResource =
            List.head
                (List.filter (existingBuild build) model.buildsWithResources.content)
    in
    setResourcesToOld existingBuildWithResource newBwr


setExistingResources : Paginated Concourse.Build -> Model -> Paginated BuildWithResources
setExistingResources paginatedBuilds model =
    paginatedMap (promoteBuild model) paginatedBuilds


updateResourcesIfNeeded : BuildWithResources -> Maybe Effect
updateResourcesIfNeeded bwr =
    case ( bwr.resources, isRunning bwr.build ) of
        ( Just resources, False ) ->
            Nothing

        _ ->
            Just <| FetchBuildResources bwr.build.id


handleJobBuildsFetched : Paginated Concourse.Build -> Model -> ( Model, List Effect )
handleJobBuildsFetched paginatedBuilds model =
    let
        newPage =
            permalink paginatedBuilds.content

        newBWRs =
            setExistingResources paginatedBuilds model
    in
    ( { model
        | buildsWithResources = newBWRs
        , currentPage = Just newPage
      }
    , List.filterMap updateResourcesIfNeeded newBWRs.content
    )


isRunning : Concourse.Build -> Bool
isRunning build =
    Concourse.BuildStatus.isRunning build.status


view : UserState -> Model -> Html Msg
view userState model =
    Html.div []
        [ Html.div
            [ style TopBar.Styles.pageIncludingTopBar
            , id "page-including-top-bar"
            ]
            [ TopBar.view userState TopBar.Model.None model.topBar
                |> HS.toUnstyled
                |> Html.map FromTopBar
            , Html.div
                [ id "page-below-top-bar", style TopBar.Styles.pageBelowTopBar ]
                [ viewMainJobsSection model ]
            ]
        ]


viewMainJobsSection : Model -> Html Msg
viewMainJobsSection model =
    Html.div [ class "with-fixed-header" ]
        [ case model.job |> RemoteData.toMaybe of
            Nothing ->
                LoadingIndicator.view

            Just job ->
                Html.div [ class "fixed-header" ]
                    [ Html.div
                        [ class <|
                            "build-header "
                                ++ headerBuildStatusClass job.finishedBuild
                        , style
                            [ ( "display", "flex" )
                            , ( "justify-content", "space-between" )
                            ]
                        ]
                        -- TODO really?
                        [ Html.div
                            [ style [ ( "display", "flex" ) ] ]
                            [ Html.button
                                [ id "pause-toggle"
                                , style <| Styles.triggerButton False
                                , onMouseEnter <| Hover Toggle
                                , onMouseLeave <| Hover None
                                , onClick TogglePaused
                                ]
                                [ Html.div
                                    [ style
                                        [ ( "background-image"
                                          , "url(/public/images/"
                                                ++ (if job.paused then
                                                        "ic-play-circle-outline.svg)"

                                                    else
                                                        "ic-pause-circle-outline-white.svg)"
                                                   )
                                          )
                                        , ( "background-position", "50% 50%" )
                                        , ( "background-repeat", "no-repeat" )
                                        , ( "width", "40px" )
                                        , ( "height", "40px" )
                                        , ( "opacity"
                                          , if model.hovered == Toggle then
                                                "1"

                                            else
                                                "0.5"
                                          )
                                        ]
                                    ]
                                    []
                                ]
                            , Html.h1 [] [ Html.span [ class "build-name" ] [ Html.text job.name ] ]
                            ]
                        , Html.button
                            [ class "trigger-build"
                            , onLeftClick TriggerBuild
                            , attribute "aria-label" "Trigger Build"
                            , attribute "title" "Trigger Build"
                            , onMouseEnter <| Hover Trigger
                            , onMouseLeave <| Hover None
                            , style <|
                                Styles.triggerButton job.disableManualTrigger
                            ]
                          <|
                            [ Html.div
                                [ style <|
                                    Styles.triggerIcon <|
                                        model.hovered
                                            == Trigger
                                            && not job.disableManualTrigger
                                ]
                                []
                            ]
                                ++ (if
                                        job.disableManualTrigger
                                            && model.hovered
                                            == Trigger
                                    then
                                        [ Html.div
                                            [ style Styles.triggerTooltip ]
                                            [ Html.text <|
                                                "manual triggering disabled "
                                                    ++ "in job config"
                                            ]
                                        ]

                                    else
                                        []
                                   )
                        ]
                    , Html.div
                        [ id "pagination-header"
                        , style
                            [ ( "display", "flex" )
                            , ( "justify-content", "space-between" )
                            , ( "align-items", "stretch" )
                            , ( "height", "60px" )
                            , ( "background-color", Colors.secondaryTopBar )
                            ]
                        ]
                        [ Html.h1
                            [ style
                                [ ( "margin", "0 18px" )
                                , ( "font-weight", "700" )
                                ]
                            ]
                            [ Html.text "builds" ]
                        , viewPaginationBar model
                        ]
                    ]
        , case model.buildsWithResources.content of
            [] ->
                LoadingIndicator.view

            anyList ->
                Html.div [ class "scrollable-body job-body" ]
                    [ Html.ul [ class "jobs-builds-list builds-list" ] <|
                        List.map (viewBuildWithResources model) anyList
                    ]
        ]


headerBuildStatusClass : Maybe Concourse.Build -> String
headerBuildStatusClass finishedBuild =
    case finishedBuild of
        Nothing ->
            ""

        Just build ->
            Concourse.BuildStatus.show build.status


viewPaginationBar : Model -> Html Msg
viewPaginationBar model =
    Html.div
        [ id "pagination"
        , style
            [ ( "display", "flex" )
            , ( "align-items", "stretch" )
            ]
        ]
        [ case model.buildsWithResources.pagination.previousPage of
            Nothing ->
                Html.div
                    [ style chevronContainer ]
                    [ Html.div
                        [ style <|
                            chevron
                                { direction = "left"
                                , enabled = False
                                , hovered = False
                                }
                        ]
                        []
                    ]

            Just page ->
                let
                    jobRoute =
                        Routes.Job { id = model.jobIdentifier, page = Just page }
                in
                Html.div
                    [ style chevronContainer
                    , onMouseEnter <| Hover PreviousPage
                    , onMouseLeave <| Hover None
                    ]
                    [ Html.a
                        [ StrictEvents.onLeftClick <| NavTo jobRoute
                        , href <| Routes.toString <| jobRoute
                        , attribute "aria-label" "Previous Page"
                        , style <|
                            chevron
                                { direction = "left"
                                , enabled = True
                                , hovered = model.hovered == PreviousPage
                                }
                        ]
                        []
                    ]
        , case model.buildsWithResources.pagination.nextPage of
            Nothing ->
                Html.div
                    [ style chevronContainer ]
                    [ Html.div
                        [ style <|
                            chevron
                                { direction = "right"
                                , enabled = False
                                , hovered = False
                                }
                        ]
                        []
                    ]

            Just page ->
                let
                    jobRoute =
                        Routes.Job { id = model.jobIdentifier, page = Just page }
                in
                Html.div
                    [ style chevronContainer
                    , onMouseEnter <| Hover NextPage
                    , onMouseLeave <| Hover None
                    ]
                    [ Html.a
                        [ StrictEvents.onLeftClick <| NavTo jobRoute
                        , href <| Routes.toString jobRoute
                        , attribute "aria-label" "Next Page"
                        , style <|
                            chevron
                                { direction = "right"
                                , enabled = True
                                , hovered = model.hovered == NextPage
                                }
                        ]
                        []
                    ]
        ]


viewBuildWithResources : Model -> BuildWithResources -> Html Msg
viewBuildWithResources model bwr =
    Html.li [ class "js-build" ] <|
        let
            buildResourcesView =
                viewBuildResources model bwr
        in
        [ viewBuildHeader model bwr.build
        , Html.div [ class "pam clearfix" ] <|
            BuildDuration.view bwr.build.duration model.now
                :: buildResourcesView
        ]


viewBuildHeader : Model -> Concourse.Build -> Html Msg
viewBuildHeader model b =
    Html.a
        [ class <| Concourse.BuildStatus.show b.status
        , StrictEvents.onLeftClick <| NavTo <| Routes.buildRoute b
        , href <| Routes.toString <| Routes.buildRoute b
        ]
        [ Html.text ("#" ++ b.name)
        ]


viewBuildResources : Model -> BuildWithResources -> List (Html Msg)
viewBuildResources model buildWithResources =
    let
        inputsTable =
            case buildWithResources.resources of
                Nothing ->
                    LoadingIndicator.view

                Just resources ->
                    Html.table [ class "build-resources" ] <|
                        List.map (viewBuildInputs model) resources.inputs

        outputsTable =
            case buildWithResources.resources of
                Nothing ->
                    LoadingIndicator.view

                Just resources ->
                    Html.table [ class "build-resources" ] <|
                        List.map (viewBuildOutputs model) resources.outputs
    in
    [ Html.div [ class "inputs mrl" ]
        [ Html.div
            [ style buildResourceHeader ]
            [ Html.span [ style <| buildResourceIcon "downward" ] []
            , Html.text "inputs"
            ]
        , inputsTable
        ]
    , Html.div [ class "outputs mrl" ]
        [ Html.div
            [ style buildResourceHeader ]
            [ Html.span [ style <| buildResourceIcon "upward" ] []
            , Html.text "outputs"
            ]
        , outputsTable
        ]
    ]


buildResourceHeader : List ( String, String )
buildResourceHeader =
    [ ( "display", "flex" )
    , ( "align-items", "center" )
    , ( "padding-bottom", "5px" )
    ]


buildResourceIcon : String -> List ( String, String )
buildResourceIcon direction =
    [ ( "background-image"
      , "url(/public/images/ic-arrow-" ++ direction ++ ".svg)"
      )
    , ( "background-position", "50% 50%" )
    , ( "background-repeat", "no-repeat" )
    , ( "background-size", "contain" )
    , ( "margin-right", "5px" )
    , ( "width", "12px" )
    , ( "height", "12px" )
    ]


viewBuildInputs : Model -> Concourse.BuildResourcesInput -> Html Msg
viewBuildInputs model bi =
    Html.tr [ class "mbs pas resource fl clearfix" ]
        [ Html.td [ class "resource-name mrm" ]
            [ Html.text bi.name
            ]
        , Html.td [ class "resource-version" ]
            [ viewVersion bi.version
            ]
        ]


viewBuildOutputs : Model -> Concourse.BuildResourcesOutput -> Html Msg
viewBuildOutputs model bo =
    Html.tr [ class "mbs pas resource fl clearfix" ]
        [ Html.td [ class "resource-name mrm" ]
            [ Html.text bo.name
            ]
        , Html.td [ class "resource-version" ]
            [ viewVersion bo.version
            ]
        ]


viewVersion : Concourse.Version -> Html Msg
viewVersion version =
    DictView.view []
        << Dict.map (\_ s -> Html.text s)
    <|
        version


subscriptions : Model -> List (Subscription Msg)
subscriptions model =
    [ OnClockTick (5 * Time.second) SubscriptionTick
    , OnClockTick (1 * Time.second) ClockTick
    ]
