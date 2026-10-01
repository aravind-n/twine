use serde::Deserialize;
use serde_json::json;
use twine_core::{HarnessId, HarnessModels, ModelListError};

#[derive(Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub(crate) struct ModelsRequest {
    pub(crate) harness: HarnessId,
}

/// A harness's models, or why they couldn't be listed, which the app shows in place of the list.
pub(crate) fn encode_models(
    result: Result<HarnessModels, ModelListError>,
) -> Result<Vec<u8>, serde_json::Error> {
    let value = match result {
        Ok(models) => json!({ "status": "listed", "models": models }),
        Err(error) => json!({ "status": "failed", "message": error.to_string() }),
    };
    serde_json::to_vec(&value)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn listed_models_and_failures_encode_for_the_app() {
        let request: ModelsRequest = serde_json::from_str(r#"{"harness":"claudeCode"}"#).unwrap();
        assert_eq!(request.harness, HarnessId::ClaudeCode);
        assert!(serde_json::from_str::<ModelsRequest>(r#"{"harness":"nope"}"#).is_err());

        let listed = encode_models(Ok(HarnessModels {
            models: vec![twine_core::HarnessModel {
                id: "opus".into(),
                name: "Opus".into(),
                group: None,
                efforts: None,
            }],
            allows_custom: true,
            efforts: vec!["high".into()],
            supports_yolo: true,
        }))
        .unwrap();
        let listed: serde_json::Value = serde_json::from_slice(&listed).unwrap();
        assert_eq!(
            listed,
            json!({"status": "listed", "models": {
                "models": [{"id": "opus", "name": "Opus"}], "allowsCustom": true, "efforts": ["high"],
                "supportsYolo": true
            }})
        );
        let failed = encode_models(Err(ModelListError::Timeout("pi"))).unwrap();
        let failed: serde_json::Value = serde_json::from_slice(&failed).unwrap();
        assert_eq!(failed["status"], "failed");
        assert_eq!(failed["message"], "pi took too long to list its models.");
    }
}
