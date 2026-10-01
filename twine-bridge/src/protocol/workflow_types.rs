use serde::{Deserialize, Serialize};
use serde_json::Value;
use twine_core::{Command, ValidationIssue, WorkflowTypeDefinition, WorkflowTypeRef};

use crate::error::BridgeError;

#[derive(Deserialize)]
struct RawDefinition {
    source: Option<WorkflowTypeRef>,
    definition: WorkflowTypeDefinition,
}

#[derive(Serialize)]
pub(super) struct WireValidationIssue {
    element: String,
    message: String,
}

impl From<&ValidationIssue> for WireValidationIssue {
    fn from(issue: &ValidationIssue) -> Self {
        Self {
            element: issue.element.to_string(),
            message: issue.problem.to_string(),
        }
    }
}

pub(super) fn decode_command(kind: &str, raw: &Value) -> Result<Command, BridgeError> {
    let raw: RawDefinition =
        serde_json::from_value(raw.clone()).map_err(|_| BridgeError::MalformedCommand)?;
    match kind {
        "validateWorkflowType" => Ok(Command::ValidateWorkflowType {
            definition: raw.definition,
        }),
        "saveWorkflowType" => Ok(Command::SaveWorkflowType {
            source: raw.source,
            definition: raw.definition,
        }),
        _ => Err(BridgeError::MalformedCommand),
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use twine_core::{BuiltinType, ElementPath, ValidationProblem};

    #[test]
    fn designer_commands_preserve_instructions_and_source_version() {
        let definition = BuiltinType::Coordinator.definition();
        let source = WorkflowTypeRef::User {
            type_id: 3,
            version: 2,
        };
        let raw = serde_json::json!({"definition": definition, "source": source});
        assert_eq!(
            decode_command("saveWorkflowType", &raw).unwrap(),
            Command::SaveWorkflowType {
                source: Some(source),
                definition: definition.clone()
            }
        );
        assert_eq!(
            decode_command("validateWorkflowType", &raw).unwrap(),
            Command::ValidateWorkflowType { definition }
        );
    }

    #[test]
    fn validation_issues_have_an_element_path_and_readable_message() {
        let issue = ValidationIssue {
            element: ElementPath::ReviewLoop(2),
            problem: ValidationProblem::LoopNotBackward,
        };
        let wire = serde_json::to_value(WireValidationIssue::from(&issue)).unwrap();
        assert_eq!(
            wire,
            serde_json::json!({"element": "review_loops[2]", "message": "must go back to an earlier stage"})
        );
    }
}
