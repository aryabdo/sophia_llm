# Sophia LLM

Pipeline de RAG/Fine-tuning para acompanhar conhecimento interno.

## Instalação automática

O instalador principal (`install_sophia_llm.sh`) agora aceita o modo totalmente
automático, útil para pipelines de provisionamento ou ambientes sem TTY.

```bash
sudo OPENAI_API_KEY="minha-chave" ./install_sophia_llm.sh --auto
```

Opções adicionais:

* `--auto-env caminho.env` – Carrega variáveis extras antes de instalar
  (formato `KEY=VAL`).
* `--auto-open-menu` – Após instalar, abre o painel interativo.
* `--auto-assume-yes` – Responde “Sim” automaticamente para prompts
  (ex.: habilitar UFW).

Caso nenhuma senha do Postgres seja informada (`DB_PASS`), o script gera uma
senha aleatória automaticamente.

## Preparando dados para fine-tuning

1. **Exporte conversas e feedbacks** que devem compor o conjunto de treino.
   - Perguntas/respostas já salvas no cache podem ser extraídas via SQL, por exemplo:
     ```bash
     psql "$DATABASE_URL" <<'SQL' > finetune/qa_cache.jsonl
     COPY (
       SELECT json_build_object(
         'question', question,
         'answer', answer,
         'citations', citations
       )
       FROM qa_cache
       WHERE created_at >= now() - interval '30 days'
     ) TO STDOUT;
     SQL
     ```
   - Feedback explícito pode ser combinado aos documentos relevantes:
     ```bash
     psql "$DATABASE_URL" <<'SQL' > finetune/feedback_pairs.jsonl
     COPY (
       SELECT json_build_object(
         'question', q.question,
         'answer', d.content,
         'metadata', json_build_object('doc_id', f.doc_id, 'signal', f.signal)
       )
       FROM feedback f
       JOIN qa_cache q ON q.qhash = f.query_hash
       JOIN docs d ON d.id = f.doc_id
       WHERE f.signal = 1
     ) TO STDOUT;
     SQL
     ```
   - Use o formato JSON Lines: **um objeto por linha**, contendo pelo menos os campos `question` e `answer` (ou `messages`).
2. **Organize os arquivos** `.jsonl` gerados dentro do diretório apontado por `FINETUNE_DIR` (padrão: `./finetune`). Cada arquivo será mesclado automaticamente pelo script.

### Exemplo de registro válido

```json
{"question": "Como inicializo o cluster?", "answer": "Execute terraform apply no diretório infra."}
```

Também é possível fornecer linhas no formato de chat do OpenAI:

```json
{"messages": [{"role": "system", "content": "Você é a Sophia."}, {"role": "user", "content": "..."}, {"role": "assistant", "content": "..."}]}
```

## Disparando o fine-tuning

1. Configure as variáveis de ambiente necessárias:
   - `OPENAI_API_KEY`: chave usada pelo cliente.
   - `FINETUNE_BASE`: modelo base (ex.: `gpt-4o-mini` ou ID do modelo corporativo).
   - `FINETUNE_DIR`: (opcional) diretório com os JSONL.
   - `ALLOW_FINETUNE=true` e `FINETUNE_TOKEN=<segredo>` para liberar o endpoint protegido.
   - `FINETUNE_HISTORY`: (opcional) caminho para registrar o histórico de jobs.
2. Certifique-se de que os arquivos JSONL estejam presentes no diretório configurado.
3. Execute o processo via CLI ou API:
   - **CLI**:
     ```bash
     python app/finetune.py            # cria um novo job
     python app/finetune.py --watch    # cria e aguarda finalizar
     python app/finetune.py --status ftjob-123 --watch  # acompanha job existente
     ```
   - **API** (quando o serviço FastAPI estiver rodando):
     ```bash
     curl -X POST "$API_URL/finetune" \
       -H "Content-Type: application/json" \
       -H "x-admin-token: $FINETUNE_TOKEN" \
       -d '{}'
     ```
     Para consultar um job:
     ```bash
     curl -X POST "$API_URL/finetune" \
       -H "Content-Type: application/json" \
       -H "x-admin-token: $FINETUNE_TOKEN" \
       -d '{"status": "ftjob-123", "watch": true}'
     ```

O script gera um arquivo `history.jsonl` (ou o caminho definido em `FINETUNE_HISTORY`) com os IDs dos jobs criados, data/hora e arquivos de origem.

## Atualizando o modelo servido

1. Após o job concluir com status `succeeded`, recupere o ID do modelo ajustado (`resulting_model`) usando:
   ```bash
   python app/finetune.py --status ftjob-123
   ```
2. Atualize as variáveis de ambiente utilizadas pelo RAG (`GEN_MODEL`, `EXPANSION_MODEL` e outras que apontem para o modelo anterior) para o novo ID.
3. Reinicie os serviços que consomem o modelo (API FastAPI, workers, TUI) para carregar a nova configuração.
4. Opcionalmente, registre a atualização no `history.jsonl` ou em um changelog interno para rastrear quando o modelo foi promovido.

Seguindo esses passos, as iterações de feedback podem ser convertidas rapidamente em dados de treinamento e implantadas no fluxo de atendimento da Sophia.
