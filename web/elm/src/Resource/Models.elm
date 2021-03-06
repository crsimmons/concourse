module Resource.Models exposing
    ( CheckStatus(..)
    , Hoverable(..)
    , Model
    , PageError(..)
    , PinnedVersion
    , Version
    , VersionEnabledState(..)
    , VersionId
    , VersionToggleAction(..)
    )

import Concourse
import Concourse.Pagination exposing (Page, Paginated)
import Date exposing (Date)
import Pinned exposing (CommentState, ResourcePinState)
import Time
import TopBar.Model


type Hoverable
    = PreviousPage
    | NextPage
    | CheckButton
    | SaveComment
    | None


type VersionToggleAction
    = Enable
    | Disable


type PageError
    = Empty
    | NotFound


type CheckStatus
    = CheckingSuccessfully
    | CurrentlyChecking
    | FailingToCheck


type alias Model =
    { pageStatus : Result PageError ()
    , checkStatus : CheckStatus
    , checkError : String
    , checkSetupError : String
    , lastChecked : Maybe Date
    , pinnedVersion : PinnedVersion
    , now : Maybe Time.Time
    , resourceIdentifier : Concourse.ResourceIdentifier
    , currentPage : Maybe Page
    , hovered : Hoverable
    , versions : Paginated Version
    , csrfToken : String
    , showPinBarTooltip : Bool
    , pinIconHover : Bool
    , topBar : TopBar.Model.Model
    , pinCommentLoading : Bool
    , ctrlDown : Bool
    , textAreaFocused : Bool
    }


type alias PinnedVersion =
    ResourcePinState Concourse.Version VersionId CommentState


type VersionEnabledState
    = Enabled
    | Changing
    | Disabled


type alias VersionId =
    Concourse.VersionedResourceIdentifier


type alias Version =
    { id : VersionId
    , version : Concourse.Version
    , metadata : Concourse.Metadata
    , enabled : VersionEnabledState
    , expanded : Bool
    , inputTo : List Concourse.Build
    , outputOf : List Concourse.Build
    , showTooltip : Bool
    }
