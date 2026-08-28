package runner

import "encoding/json"

const maxControlMessage = 256 * 1024

type Offer struct {
	AttemptID        string    `json:"attempt_id"`
	IdempotencyToken string    `json:"idempotency_token"`
	SourceURL        *string   `json:"source_url"`
	SecretsURL       string    `json:"secrets_url"`
	BuiltinsURL      string    `json:"builtins_url"`
	Execution        Execution `json:"execution"`
}

type Execution struct {
	AttemptID        string                     `json:"attempt_id"`
	IdempotencyToken string                     `json:"idempotency_token"`
	Image            string                     `json:"image"`
	Shell            string                     `json:"shell"`
	TimeoutMS        int64                      `json:"timeout_ms"`
	Env              map[string]string          `json:"env"`
	BuildEnv         map[string]string          `json:"build_env"`
	SecretNames      []string                   `json:"secret_names"`
	Services         map[string]json.RawMessage `json:"services"`
	Steps            []Step                     `json:"steps"`
}

type Step struct {
	Name      string         `json:"name"`
	Kind      string         `json:"kind"`
	Value     string         `json:"value"`
	Condition string         `json:"condition"`
	With      map[string]any `json:"with"`
}

type channelReply struct {
	Status   string         `json:"status"`
	Response map[string]any `json:"response"`
}

type enrollmentResponse struct {
	RunnerID   string `json:"runner_id"`
	Credential string `json:"credential"`
}
