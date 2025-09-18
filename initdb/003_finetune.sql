CREATE TABLE IF NOT EXISTS finetune_runs (
  id BIGSERIAL PRIMARY KEY,
  provider TEXT NOT NULL DEFAULT 'openai',
  base_model TEXT NOT NULL,
  job_id TEXT,
  status TEXT,
  trained_model_id TEXT,
  started_at TIMESTAMPTZ DEFAULT now(),
  finished_at TIMESTAMPTZ,
  train_file_id TEXT,
  val_file_id TEXT,
  params JSONB DEFAULT '{}'::jsonb
);
CREATE INDEX IF NOT EXISTS idx_ftr_status ON finetune_runs(status);
