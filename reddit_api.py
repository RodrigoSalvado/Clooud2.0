import os
import logging
import requests
import pandas as pd
from requests.auth import HTTPBasicAuth
from azure.cosmos import CosmosClient, exceptions

logging.basicConfig(level=logging.DEBUG)
logger = logging.getLogger(__name__)

# Configuração da API Reddit
CLIENT_ID = os.getenv('CLIENT_ID')
SECRET = os.getenv('SECRET')
REDDIT_USER = os.getenv('REDDIT_USER')

# Configuração do Cosmos DB (lê via os.getenv)
COSMOS_ENDPOINT = os.getenv('COSMOS_ENDPOINT')
COSMOS_KEY = os.getenv('COSMOS_KEY')
DATABASE_NAME = os.getenv('COSMOS_DATABASE')
CONTAINER_NAME = os.getenv('COSMOS_CONTAINER')

# Estado interno do cliente Cosmos
_cosmos_client = None
_cosmos_container = None

def _get_reddit_token():
    client_id     = os.getenv("CLIENT_ID")
    client_secret = os.getenv("SECRET")
    username      = os.getenv("REDDIT_USER")
    password      = os.getenv("REDDIT_PASSWORD")
    if not all([client_id, client_secret, username, password]):
        raise RuntimeError("Defina CLIENT_ID, SECRET, REDDIT_USER e REDDIT_PASSWORD")

    auth = HTTPBasicAuth(client_id, client_secret)
    data = {"grant_type":"password","username":username,"password":password}
    headers = {"User-Agent":f"{username}/0.1 by {username}"}
    res = requests.post("https://www.reddit.com/api/v1/access_token",
                        auth=auth, data=data, headers=headers)
    res.raise_for_status()
    return res.json()["access_token"]


def _init_cosmos():
    endpoint = os.getenv("COSMOS_ENDPOINT")
    key      = os.getenv("COSMOS_KEY")
    if not endpoint or not key:
        raise RuntimeError("COSMOS_ENDPOINT e COSMOS_KEY não definidas")
    client    = CosmosClient(endpoint, key)
    db        = client.create_database_if_not_exists(os.getenv("COSMOS_DATABASE", "RedditApp"))
    container = db.create_container_if_not_exists(
        id=os.getenv("COSMOS_CONTAINER", "posts"),
        partition_key={"/path":"/subreddit"}
    )
    return container




def busca_reddit(subreddit, sort="hot", num=10, save_to_db=True):
    # 1) Autentica e busca
    token = _get_reddit_token()
    url   = f"https://oauth.reddit.com/r/{subreddit}/{sort}"
    headers = {
        "Authorization":f"bearer {token}",
        "User-Agent":f"{os.getenv('REDDIT_USER')}/0.1"
    }
    params = {"limit": num}
    res = requests.get(url, headers=headers, params=params)
    res.raise_for_status()
    data = res.json().get("data",{})

    # 2) Valida e monta lista de posts
    children = data.get("children", [])
    if not isinstance(children, list):
        raise ValueError(f"Resposta inesperada para r/{subreddit}")

    posts = []
    for child in children:
        d = child.get("data", {})
        # Garante que haja um id único
        reddit_id = d.get("id")
        if not reddit_id:
            continue
        posts.append({
            "id":       f"{subreddit}_{reddit_id}",  # ID requerido pelo Cosmos
            "subreddit":subreddit,
            "title":    d.get("title",""),
            "url":      d.get("url",""),
            "score":    d.get("score",0)
        })

    # 3) Persiste no Cosmos
    if save_to_db and posts:
        container = _init_cosmos()
        for p in posts:
            try:
                container.upsert_item(p)
                logger.info(f"Upserted: {p['id']}")
            except exceptions.CosmosHttpResponseError as e:
                logger.error(f"Falha ao upsert {p['id']}", exc_info=e)
                raise

    return posts



def get_posts_from_cosmos(subreddit: str, max_items: int = 100) -> list:
    """
    Consulta o Cosmos DB e retorna posts do subreddit ordenados por timestamp.

    Args:
        subreddit: Nome do subreddit para filtrar.
        max_items: Número máximo de items a retornar.

    Returns:
        Lista de documentos do Cosmos DB correspondentes aos posts.
    """
    container = _init_cosmos()
    query = (
        f"SELECT TOP {max_items} * FROM c WHERE c.subreddit = @subreddit ORDER BY c._ts DESC"
    )
    parameters = [{"name": "@subreddit", "value": subreddit}]
    items = list(
        container.query_items(
            query=query,
            parameters=parameters,
            enable_cross_partition_query=True
        )
    )
    return items


if __name__ == '__main__':
    sub = 'elonmusk'
    posts = busca_reddit(sub, sort='new', limit=5)
    print(f"Ingestão: {len(posts)} posts de /r/{sub} guardados no Cosmos DB.")

    saved = get_posts_from_cosmos(sub, max_items=5)
    print(f"Leitura: {len(saved)} posts lidos do Cosmos DB.")
