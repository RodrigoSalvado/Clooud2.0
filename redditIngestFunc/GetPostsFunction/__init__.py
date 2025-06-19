import logging
import azure.functions as func
import os
import json
from azure.cosmos import CosmosClient

COSMOS_ENDPOINT = os.getenv("COSMOS_ENDPOINT")
COSMOS_KEY = os.getenv("COSMOS_KEY")
COSMOS_DATABASE = os.getenv("COSMOS_DATABASE", "RedditApp")
COSMOS_CONTAINER = os.getenv("COSMOS_CONTAINER", "posts")

cosmos_client = None
cosmos_container = None

def get_cosmos_container():
    global cosmos_client, cosmos_container
    if cosmos_client is None:
        if not COSMOS_ENDPOINT or not COSMOS_KEY:
            logging.error("COSMOS_ENDPOINT ou COSMOS_KEY não definidos.")
            raise RuntimeError("Configuração do Cosmos DB ausente.")
        cosmos_client = CosmosClient(COSMOS_ENDPOINT, COSMOS_KEY)
        db_client = cosmos_client.get_database_client(COSMOS_DATABASE)
        cosmos_container = db_client.get_container_client(COSMOS_CONTAINER)
    return cosmos_container

def main(req: func.HttpRequest) -> func.HttpResponse:
    logging.info("Função HTTP recebida.")

    if req.method == "GET":
        return handle_get(req)
    elif req.method == "PUT":
        return handle_put(req)
    else:
        return func.HttpResponse(
            json.dumps({"error": "Método não suportado. Usa GET ou PUT."}),
            status_code=405,
            mimetype="application/json"
        )

def handle_get(req: func.HttpRequest) -> func.HttpResponse:
    ids = []
    try:
        ids_param = req.params.get("ids")
        if ids_param:
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

    partitioned = {}
    for item_id in ids:
        if "_" not in item_id:
            logging.warning(f"ID inválido: {item_id}, ignorado.")
            continue
        subreddit_pk, _ = item_id.split("_", 1)
        partitioned.setdefault(subreddit_pk, []).append(item_id)

    results = []
    for subreddit, id_list in partitioned.items():
        try:
            query = f"SELECT * FROM c WHERE c.id IN ({','.join(['@id'+str(i) for i in range(len(id_list))])})"
            parameters = [{"name": "@id"+str(i), "value": id_val} for i, id_val in enumerate(id_list)]
            items = list(container.query_items(
                query=query,
                parameters=parameters,
                partition_key=subreddit
            ))
            for item in items:
                sanitized = {
                    "id": item.get("id"),
                    "subreddit": item.get("subreddit"),
                    "title": item.get("title"),
                    "selftext": item.get("selftext"),
                    "url": item.get("url"),
                }
                results.append(sanitized)
        except Exception as e:
            logging.error(f"Erro na query para subreddit {subreddit}: {e}", exc_info=True)
            continue

    return func.HttpResponse(
        json.dumps({"posts": results}, ensure_ascii=False),
        status_code=200,
        mimetype="application/json"
    )

def handle_put(req: func.HttpRequest) -> func.HttpResponse:
    try:
        data = req.get_json()
    except Exception:
        return func.HttpResponse(
            json.dumps({"error": "Corpo JSON inválido."}),
            status_code=400,
            mimetype="application/json"
        )

    if not isinstance(data, dict) or "updates" not in data or not isinstance(data["updates"], list):
        return func.HttpResponse(
            json.dumps({"error": "Formato esperado: {\"updates\": [{\"id\": \"subreddit_xxx\", \"confiabilidade\": valor, \"sentimento\": valor}, ...]}"}),
            status_code=400,
            mimetype="application/json"
        )

    updates = data["updates"]
    if not updates:
        return func.HttpResponse(
            json.dumps({"error": "Lista de updates vazia."}),
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

    success = []
    failed = []

    for update in updates:
        try:
            item_id = update.get("id")
            confiabilidade = update.get("confiabilidade")
            sentimento = update.get("sentimento")

            if not item_id or confiabilidade is None or sentimento is None:
                failed.append({"id": item_id, "error": "Faltam campos obrigatórios."})
                continue

            if "_" not in item_id:
                failed.append({"id": item_id, "error": "ID inválido."})
                continue

            subreddit_pk, _ = item_id.split("_", 1)

            item = container.read_item(item=item_id, partition_key=subreddit_pk)
            item["confiabilidade"] = confiabilidade
            item["sentimento"] = sentimento

            container.replace_item(item=item_id, body=item)
            success.append(item_id)

        except Exception as e:
            logging.error(f"Erro ao actualizar ID {update.get('id')}: {e}", exc_info=True)
            failed.append({"id": update.get("id"), "error": str(e)})

    return func.HttpResponse(
        json.dumps({"actualizados": success, "falhados": failed}, ensure_ascii=False),
        status_code=200,
        mimetype="application/json"
    )
