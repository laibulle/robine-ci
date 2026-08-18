use chrono::{DateTime, Utc};
use serde::{Deserialize, Serialize};
use thiserror::Error;
use uuid::Uuid;

#[derive(Clone, Copy, Debug, Deserialize, Eq, PartialEq, Serialize)]
#[serde(rename_all = "snake_case")]
pub enum Role {
    Administrator,
    Maintainer,
    Viewer,
}

impl Role {
    #[must_use]
    pub const fn as_str(self) -> &'static str {
        match self {
            Self::Administrator => "administrator",
            Self::Maintainer => "maintainer",
            Self::Viewer => "viewer",
        }
    }
}

impl TryFrom<&str> for Role {
    type Error = UnknownRole;

    fn try_from(value: &str) -> Result<Self, Self::Error> {
        match value {
            "administrator" => Ok(Self::Administrator),
            "maintainer" => Ok(Self::Maintainer),
            "viewer" => Ok(Self::Viewer),
            unknown => Err(UnknownRole(unknown.into())),
        }
    }
}

#[derive(Clone, Debug, Eq, PartialEq, Serialize)]
pub struct User {
    pub id: Uuid,
    pub email: String,
    pub role: Role,
    pub disabled: bool,
    pub inserted_at: DateTime<Utc>,
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct LocalIdentity {
    pub user: User,
    pub password_hash: String,
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct OidcClaims {
    pub issuer: String,
    pub subject: String,
    pub email: String,
    pub email_verified: bool,
}

#[derive(Clone, Debug, Eq, PartialEq, Serialize)]
pub struct OidcAuthorization {
    pub url: String,
    pub state: String,
}

#[derive(Debug, Error, Eq, PartialEq)]
#[error("unknown identity role: {0}")]
pub struct UnknownRole(String);
