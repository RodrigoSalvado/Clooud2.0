import logging
import azure.functions as func
import os
import json
from azure.cosmos import CosmosClient

# Configuração Cosmos (lê das Application Settings da Function App)
COSMOS_ENDPOINT = os.getenv("COSMOS_ENDPOINT")
COSMOS_KEY = os.getenv("COSMOS_KEY")
COSMOS_DATABASE = os.getenv("COSMOS_DATABASE", "RedditApp")
COSMOS_CONTAINER = os.getenv("COSMOS_CONTAINER", "posts")

# Inicialização do client Cosmos (pode ser global para reuso entre invocações)
cosmos_client = None
cosmos_container = None

def get_cosmos_container():
    global cosmos_client, cosmos_container
    if cosmos_client is None:
        if not COSMOS_ENDPOINT or not COSMOS_KEY:
            logging.error("COSMOS_ENDPOINT ou COSMOS_KEY não definidos na Function GetPostsFunction.")
            raise RuntimeError("Configuração do Cosmos DB ausente.")
        cosmos_client = CosmosClient(COSMOS_ENDPOINT, COSMOS_KEY)
        db_client = cosmos_client.get_database_client(COSMOS_DATABASE)
        cosmos_container = db_client.get_container_client(COSMOS_CONTAINER)
    return cosmos_container

def main(req: func.HttpRequest) -> func.HttpResponse:
    logging.info("GetPostsFunction recebida.")

    # Exemplo: IDs podem vir via query param ?ids=id1,id2,id3 ou via body JSON { "ids": ["id1", ...] }
    ids = []
    try:
        ids_param = req.params.get("ids")
        if ids_param:
            # separar por vírgula
            ids = [i.strip() for i in ids_param.split(",") if i.strip()]
        else:
            try:
                body = req.get_json()
                if isinstance(body, dict) and "ids" in body and isinstance(body["ids"], list):
                    ids = body["ids"]
            except ValueError:
                pass
    except Exception as e:
        logging.error(f"Erro ao ler parâmetros: {e}", exc_info=True)
        return func.HttpResponse(
            json.dumps({"error": "Parâmetro inválido"}),
            status_code=400,
            mimetype="application/json"
        )
    if not ids:
        return func.HttpResponse(
            json.dumps({"error": "É preciso informar lista de IDs, ex: ?ids=subreddit_abc,subreddit_def"}),
            status_code=400,
            mimetype="application/json"
        )

    try:
        container = get_cosmos_container()
    except Exception as e:
        logging.error(f"Falha ao conectar ao Cosmos: {e}", exc_info=True)
        return func.HttpResponse(
            json.dumps({"error": "Falha na configuração do Cosmos DB."}),
            status_code=500,
            mimetype="application/json"
        )

    results = []
    for item_id in ids:
        # extrair partition key (subreddit) a partir do ID: prefix antes de "_" 
        if "_" not in item_id:
            logging.warning(f"ID inválido/no formato esperado: {item_id}, pulando.")
            continue
        subreddit_pk, _ = item_id.split("_", 1)
        try:
            item = container.read_item(item=item_id, partition_key=subreddit_pk)
            # opcional: sanitize fields antes de retornar
            sanitized = {
                "id": item.get("id"),
                "subreddit": item.get("subreddit"),
                "title": item.get("title"),
                "selftext": item.get("selftext"),
                "url": item.get("url"),
                # quaisquer outros campos necessários
            }
            results.append(sanitized)
        except Exception as e:
            logging.error(f"Erro ao ler item {item_id}: {e}", exc_info=True)
            # opcional: incluir um aviso no retorno
            # results.append({"id": item_id, "error": str(e)})
            continue

    # Retorna JSON com lista de posts
    return func.HttpResponse(
        json.dumps({"posts": results}, ensure_ascii=False),
        status_code=200,
        mimetype="application/json"
    )
