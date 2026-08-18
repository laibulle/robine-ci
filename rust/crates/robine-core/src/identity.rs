use serde::Serialize;
use thiserror::Error;
use uuid::Uuid;

#[derive(Clone, Copy, Debug, Eq, PartialEq, Serialize)]
#[serde(rename_all = "snake_case")]
pub enum Role {
    Administrator,
    Maintainer,
    Viewer,
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
}

#[derive(Debug, Error, Eq, PartialEq)]
#[error("unknown identity role: {0}")]
pub struct UnknownRole(String);
