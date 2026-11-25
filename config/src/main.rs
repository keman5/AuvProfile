use serde::{Deserialize, Serialize};
use std::io;
use toml_edit::{value, DocumentMut, Item, Table, TableLike};

#[derive(Debug, Default, Deserialize, Serialize)]
struct Provider {
    id: String,
    name: Option<String>,
    base_url: Option<String>,
    env_key: Option<String>,
    experimental_bearer_token: Option<String>,
    wire_api: Option<String>,
    requires_openai_auth: Option<bool>,
}

impl Provider {
    fn read(id: &str, table: &dyn TableLike) -> Self {
        let string = |key| table.get(key).and_then(Item::as_str).map(str::to_owned);
        Self {
            id: id.to_owned(),
            name: string("name"),
            base_url: string("base_url"),
            env_key: string("env_key"),
            experimental_bearer_token: string("experimental_bearer_token"),
            wire_api: string("wire_api"),
            requires_openai_auth: table.get("requires_openai_auth").and_then(Item::as_bool),
        }
    }

    fn write(self, table: &mut dyn TableLike) {
        for (key, entry) in [
            ("name", self.name),
            ("base_url", self.base_url),
            ("env_key", self.env_key),
            ("experimental_bearer_token", self.experimental_bearer_token),
            ("wire_api", self.wire_api),
        ] {
            set(table, key, entry.map(value));
        }
        set(
            table,
            "requires_openai_auth",
            self.requires_openai_auth.map(value),
        );
    }
}

fn set(table: &mut dyn TableLike, key: &str, item: Option<Item>) {
    match item {
        Some(mut new) => {
            if let Some(old) = table.get(key).and_then(Item::as_value) {
                if let Some(new_value) = new.as_value_mut() {
                    *new_value.decor_mut() = old.decor().clone();
                }
            }
            table.insert(key, new);
        }
        None => {
            table.remove(key);
        }
    }
}

#[derive(Deserialize)]
#[serde(tag = "operation", rename_all = "snake_case")]
enum Operation {
    Inspect,
    Activate { id: Option<String> },
    Update { provider: Provider },
}

#[derive(Deserialize)]
struct Request {
    source: String,
    #[serde(flatten)]
    operation: Operation,
}

#[derive(Default, Serialize)]
struct Response {
    active: Option<String>,
    auth_store: Option<String>,
    providers: Vec<Provider>,
    profiles: Vec<String>,
    text: Option<String>,
}

fn run(request: Request) -> Result<Response, &'static str> {
    let mut doc: DocumentMut = request.source.parse().map_err(|_| "Invalid TOML")?;
    match request.operation {
        Operation::Inspect => {
            let tables = |key| doc.get(key).and_then(Item::as_table_like);
            let providers = tables("model_providers")
                .into_iter()
                .flat_map(TableLike::iter)
                .filter_map(|(id, item)| {
                    item.as_table_like().map(|table| Provider::read(id, table))
                })
                .collect();
            let profiles = tables("profiles")
                .into_iter()
                .flat_map(TableLike::iter)
                .filter(|(_, item)| item.is_table_like())
                .map(|(key, _)| key.to_owned())
                .collect();
            Ok(Response {
                active: doc
                    .get("model_provider")
                    .and_then(Item::as_str)
                    .map(str::to_owned),
                auth_store: doc
                    .get("cli_auth_credentials_store")
                    .and_then(Item::as_str)
                    .map(str::to_owned),
                providers,
                profiles,
                text: None,
            })
        }
        Operation::Activate { id } => {
            if let Some(id) = id.as_deref() {
                let built_in = matches!(id, "openai" | "ollama" | "lmstudio");
                let exists = doc
                    .get("model_providers")
                    .and_then(Item::as_table_like)
                    .is_some_and(|t| t.contains_key(id));
                if !built_in && !exists {
                    return Err("Provider no longer exists");
                }
            }
            set(doc.as_table_mut(), "model_provider", id.map(value));
            Ok(Response {
                text: Some(doc.to_string()),
                ..Response::default()
            })
        }
        Operation::Update { provider } => {
            let id = provider.id.clone();
            if id.trim().is_empty() {
                return Err("A provider identifier is required");
            }
            if !doc.as_table().contains_key("model_providers") {
                doc["model_providers"] = Item::Table(Table::new());
            }
            let providers = doc
                .get_mut("model_providers")
                .and_then(Item::as_table_like_mut)
                .ok_or("model_providers must be a table")?;
            if !providers.contains_key(&id) {
                if doc_string_key(&id) {
                    return Err("Built-in provider identifiers are reserved");
                }
                providers.insert(&id, Item::Table(Table::new()));
            }
            let table = providers
                .get_mut(&id)
                .and_then(Item::as_table_like_mut)
                .ok_or("Provider must be a table")?;
            provider.write(table);
            Ok(Response {
                text: Some(doc.to_string()),
                ..Response::default()
            })
        }
    }
}

fn doc_string_key(id: &str) -> bool {
    matches!(id, "openai" | "ollama" | "lmstudio")
}

fn main() {
    let result = serde_json::from_reader::<_, Request>(io::stdin().lock())
        .map_err(|_| "Invalid configuration request")
        .and_then(run);
    match result {
        Ok(response) => {
            if serde_json::to_writer(io::stdout().lock(), &response).is_err() {
                std::process::exit(2);
            }
        }
        Err(error) => {
            eprintln!("{error}");
            std::process::exit(1);
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn preserves_existing_settings_and_comments() {
        let source = "# project setup\nmodel_provider = 'openai' # current\n[model_providers.local]\nname = 'Local'\nbase_url = 'http://127.0.0.1:8080' # local\n[model_providers.local.http_headers]\nX-Custom = 'keep'\n[profiles.work]\nmodel = 'example'\n";
        let provider = Provider {
            id: "local".into(),
            name: Some("New name".into()),
            base_url: Some("http://127.0.0.1:8000".into()),
            experimental_bearer_token: Some("synthetic-token".into()),
            ..Provider::default()
        };
        let updated = run(Request {
            source: source.into(),
            operation: Operation::Update { provider },
        })
        .unwrap()
        .text
        .unwrap();
        assert!(updated.contains("# local"));
        assert!(updated.contains("X-Custom = 'keep'"));
        assert!(updated.contains("[profiles.work]"));
        let activated = run(Request {
            source: updated,
            operation: Operation::Activate {
                id: Some("local".into()),
            },
        })
        .unwrap()
        .text
        .unwrap();
        assert!(activated.contains("model_provider = \"local\" # current"));
        let parsed = run(Request {
            source: activated,
            operation: Operation::Inspect,
        })
        .unwrap();
        assert_eq!(
            parsed.providers[0].experimental_bearer_token.as_deref(),
            Some("synthetic-token")
        );
        assert_eq!(parsed.profiles, ["work"]);
    }
}
