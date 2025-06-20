import os
import logging
import re
from datetime import datetime

import numpy as np
import pandas as pd
import matplotlib.pyplot as plt
from scipy.stats import gaussian_kde
from wordcloud import WordCloud, STOPWORDS
from transformers import pipeline

import requests
from flask import Flask, render_template, request, flash, redirect, url_for, session
from azure.storage.blob import BlobClient, ContainerClient, ContentSettings

from azure.cosmos import CosmosClient

# Liga ao Cosmos uma vez ao iniciar a app
COSMOS_ENDPOINT = os.getenv("COSMOS_ENDPOINT")
COSMOS_KEY = os.getenv("COSMOS_KEY")
COSMOS_DATABASE = os.getenv("COSMOS_DATABASE", "RedditApp")
COSMOS_CONTAINER = os.getenv("COSMOS_CONTAINER", "posts")

assert COSMOS_ENDPOINT and COSMOS_KEY, "Falta o Cosmos Endpoint ou Key"

cosmos_client = CosmosClient(COSMOS_ENDPOINT, credential=COSMOS_KEY)
db_client = cosmos_client.get_database_client(COSMOS_DATABASE)
cont_client = db_client.get_container_client(COSMOS_CONTAINER)

logging.basicConfig(level=logging.INFO)
logger = logging.getLogger(__name__)

app = Flask(__name__)
# Use uma variável de ambiente para a chave secreta; em dev, cai no padrão “dev_secret_key”
app.secret_key = os.getenv("FLASK_SECRET_KEY", "dev_secret_key")

# Sessão cookie config
app.config["SESSION_COOKIE_SECURE"] = False
app.config["SESSION_COOKIE_SAMESITE"] = "Lax"
# Em produção HTTPS, poderia ser:
# app.config["SESSION_COOKIE_SECURE"] = True
# app.config["SESSION_COOKIE_SAMESITE"] = "None"

# Variáveis de ambiente esperadas
FUNCTION_URL = os.getenv("FUNCTION_URL")        # e.g. https://<sua-func>.azurewebsites.net/api/search?code=...
GET_POSTS_FUNCTION_URL = os.getenv("GET_POSTS_FUNCTION_URL")  # e.g. https://<sua-func>.azurewebsites.net/api/getposts?code=...
CONTAINER_ENDPOINT_SAS = os.getenv("CONTAINER_ENDPOINT_SAS")  # e.g. https://<storage>.blob.core.windows.net/<container>?<sas>

# Inicializar pipeline de análise de sentimento (sentiment-analysis padrão, leve)
try:
    classifier = pipeline("sentiment-analysis")
    logger.info("Pipeline de sentiment-analysis carregado com sucesso.")
except Exception as e:
    logger.error("Falha ao inicializar pipeline de sentiment-analysis: %s", e, exc_info=True)
    classifier = None

def fetch_and_ingest_posts(subreddit: str, sort: str, limit: int):
    """
    Chama a Azure Function que ingere do Reddit e retorna lista de posts.
    Espera que a Azure Function retorne JSON com chave "posts": [...], ou liste diretamente.
    """
    if not FUNCTION_URL:
        raise RuntimeError("FUNCTION_URL não está configurado")
    params = {"subreddit": subreddit, "sort": sort, "limit": limit}
    logger.info(f"[fetch_and_ingest_posts] Chamando FUNCTION_URL={FUNCTION_URL} com params={params}")
    resp = requests.get(FUNCTION_URL, params=params, timeout=30)
    try:
        resp.raise_for_status()
    except Exception:
        logger.error(f"[fetch_and_ingest_posts] Status code != 200: {resp.status_code}, body: {resp.text}")
        resp.raise_for_status()
    data = resp.json()
    # Tenta extrair key "posts", mas aceita caso retorne lista diretamente
    if isinstance(data, dict) and "posts" in data and isinstance(data["posts"], list):
        posts = data["posts"]
    elif isinstance(data, list):
        posts = data
    else:
        logger.warning(f"[fetch_and_ingest_posts] JSON inesperado: {data!r}")
        posts = []
    logger.info(f"[fetch_and_ingest_posts] Recebeu {len(posts)} posts")
    return posts

def get_posts_from_cosmos(ids: list[str]):
    """
    Chama a Azure Function GET_POSTS com query param "ids=id1,id2,...", retorna lista de posts do Cosmos.
    Espera que a resposta JSON seja {"posts": [...]} ou lista diretamente.
    """
    if not GET_POSTS_FUNCTION_URL:
        raise RuntimeError("GET_POSTS_FUNCTION_URL não está configurado")
    if not ids:
        return []
    ids_param = ",".join(ids)
    logger.info(f"[get_posts_from_cosmos] Chamando GET_POSTS_FUNCTION_URL={GET_POSTS_FUNCTION_URL} com ids={ids_param}")
    resp = requests.get(GET_POSTS_FUNCTION_URL, params={"ids": ids_param}, timeout=30)
    try:
        resp.raise_for_status()
    except Exception:
        logger.error(f"[get_posts_from_cosmos] Status code != 200: {resp.status_code}, body: {resp.text}")
        resp.raise_for_status()
    data = resp.json()
    if isinstance(data, dict) and "posts" in data and isinstance(data["posts"], list):
        posts = data["posts"]
    elif isinstance(data, list):
        posts = data
    else:
        logger.warning(f"[get_posts_from_cosmos] JSON inesperado: {data!r}")
        posts = []
    logger.info(f"[get_posts_from_cosmos] Recebeu {len(posts)} posts do Cosmos")
    return posts

@app.route("/", methods=["GET"])
def home():
    # Limpa sessão de pesquisas anteriores
    session.pop("post_ids", None)
    session.pop("search_params", None)
    session.pop("posts_raw", None)
    # Passa valores padrão para campos do formulário
    return render_template("index.html", posts=None, subreddit="", sort="hot", limit=10)

@app.route("/search", methods=["GET"])
def search():
    subreddit = request.args.get("subreddit", "").strip()
    sort = request.args.get("sort", "hot").strip()
    limit_str = request.args.get("limit", "10").strip()

    if not subreddit:
        flash("Informe o nome do subreddit.", "warning")
        return redirect(url_for("home"))
    try:
        limit = int(limit_str)
    except ValueError:
        flash("O campo 'Número de posts' deve ser um número inteiro.", "warning")
        return redirect(url_for("home"))

    # 1) Chama ingestão do Reddit → Cosmos
    try:
        posts = fetch_and_ingest_posts(subreddit, sort, limit)
        logger.info(f"[SEARCH] fetch_and_ingest_posts retornou tipo {type(posts)}, len={len(posts)}")
    except Exception as e:
        logger.error(f"Erro ao obter/ingerir posts do Reddit: {e}", exc_info=True)
        flash(f"Erro ao obter posts do Reddit: {e}", "danger")
        return redirect(url_for("home"))

    # 2) Extrai IDs válidos, montando <subreddit>_<raw_id>
    post_ids = []
    posts_with_full = []
    if isinstance(posts, list):
        for p in posts:
            raw_id = p.get("id")
            if raw_id:
                # Evita duplicar prefixo se API já retornou algo como "<subreddit>_<id>"
                if "_" in raw_id:
                    full_id = raw_id
                else:
                    full_id = f"{subreddit}_{raw_id}"
                post_ids.append(full_id)
                # adiciona campo full_id ao post para uso posterior
                p_copy = p.copy()
                p_copy['full_id'] = full_id
                posts_with_full.append(p_copy)
    if not post_ids:
        logger.warning("[SEARCH] Nenhum post com campo 'id' retornado pela ingestão.")
        flash("Nenhum post válido retornado da ingestão.", "warning")
        return redirect(url_for("home"))

    # 3) Salva na sessão, adicionando log dos IDs
    max_show = 20
    if len(post_ids) > max_show:
        logger.info(f"[SEARCH] IDs a armazenar na sessão (mostrando apenas os {max_show} primeiros de {len(post_ids)}): {post_ids[:max_show]} ...")
    else:
        logger.info(f"[SEARCH] IDs a armazenar na sessão: {post_ids}")
    session["post_ids"] = post_ids
    session["search_params"] = {"subreddit": subreddit, "sort": sort, "limit": limit}
    # Armazena posts brutos para uso no detail_all sem nova chamada externa
    # Atenção: deve ser serializável (dicts, listas, strings, ints)
    session["posts_raw"] = posts_with_full
    logger.info(f"[SEARCH] session['post_ids'] salvo (total {len(post_ids)} IDs) e session['posts_raw'].")

    # 4) Buscar dados completos via Cosmos usando os IDs completos
    try:
        cosmos_posts = get_posts_from_cosmos(post_ids)
        logger.info(f"[SEARCH] get_posts_from_cosmos retornou len={len(cosmos_posts)}")
        if isinstance(cosmos_posts, list) and not cosmos_posts:
            logger.warning("[SEARCH] get_posts_from_cosmos retornou lista vazia; usando posts brutos como fallback")
            cosmos_posts = posts_with_full
        else:
            # Se vier do Cosmos, mapeia campo 'id' para 'full_id'
            new_list = []
            for doc in cosmos_posts:
                d = doc.copy()
                if 'id' in d:
                    d['full_id'] = d['id']
                new_list.append(d)
            cosmos_posts = new_list
    except Exception as e:
        logger.error(f"Erro ao buscar posts do Cosmos: {e}", exc_info=True)
        flash(f"Erro ao buscar posts do Cosmos: {e}", "danger")
        cosmos_posts = posts_with_full  # fallback

    # 5) Renderiza template com posts
    # No template index.html, ao iterar posts, use post.full_id para inputs
    return render_template("index.html",
                           posts=cosmos_posts,
                           subreddit=subreddit,
                           sort=sort,
                           limit=limit)

@app.route("/detail_all", methods=["POST"])
def detail_all():
    ids_form = request.form.getlist('ids[]') or request.form.getlist('ids')
    if ids_form:
        post_ids = ids_form
        session["post_ids"] = post_ids
    else:
        post_ids = session.get("post_ids", [])

    if not post_ids:
        flash("Nenhum post disponível para análise.", "warning")
        return redirect(url_for("home"))

    if classifier is None:
        flash("Pipeline de sentimento não está disponível.", "danger")
        return redirect(url_for("home"))

    # 1️⃣ Buscar posts do Cosmos
    try:
        posts = get_posts_from_cosmos(post_ids)
    except Exception as e:
        logger.error(f"Erro ao buscar posts do Cosmos em detail_all: {e}", exc_info=True)
        posts = []

    if not posts:
        raw_posts = session.get("posts_raw", [])
        posts = [p.copy() for p in raw_posts if p.get('full_id') in post_ids]

    if not posts:
        flash("Não há posts para análise.", "warning")
        return redirect(url_for("home"))

    analysed_posts = []
    text_accum = []
    neg_probs, neu_probs, pos_probs = [], [], []

    texts = []
    posts_index = []
    for idx, post in enumerate(posts):
        snippet = post.get('selftext', '').strip() or post.get('title', '').strip()
        if snippet:
            snippet = snippet[:512]
            texts.append(snippet)
            posts_index.append(idx)
        else:
            post['sentimento'] = 'Unknown'
            post['probabilidade'] = 0
            analysed_posts.append(post)

    batch_size = 16
    for start in range(0, len(texts), batch_size):
        batch_texts = texts[start:start+batch_size]
        try:
            results = classifier(batch_texts, truncation=True)
        except Exception as e:
            logger.error(f"Erro no batch de sentimento: {e}", exc_info=True)
            results = [{} for _ in batch_texts]

        for j, res in enumerate(results):
            idx = posts_index[start + j]
            post = posts[idx]
            label = res.get('label', 'Unknown')
            score = res.get('score', 0.0)
            prob = int(score * 100)
            label_cap = label.capitalize() if isinstance(label, str) else 'Unknown'

            post['sentimento'] = label_cap
            post['probabilidade'] = prob

            if label.lower() == 'negative':
                neg_probs.append(prob)
            elif label.lower() == 'positive':
                pos_probs.append(prob)
            else:
                neu_probs.append(prob)

            text_accum.append(batch_texts[j])
            analysed_posts.append(post)

    # 2️⃣ UPDATE directo no Cosmos
    try:
        for post in analysed_posts:
            full_id = post.get('id') or post.get('full_id')
            if not full_id or "_" not in full_id:
                continue
            pk = full_id.split("_", 1)[0].strip()

            item = cont_client.read_item(item=full_id, partition_key=pk)
            item["sentimento"] = post['sentimento']
            item["confiabilidade"] = round(post['probabilidade'] / 100, 4)

            cont_client.replace_item(item=full_id, body=item)
            logger.info(f"✅ Actualizado: {full_id}")
    except Exception as e:
        logger.error("Erro ao actualizar no Cosmos: %s", e, exc_info=True)
        flash(f"Erro ao actualizar no Cosmos: {e}", "danger")

    # 3️⃣ Gráfico de KDE
    import os
    os.makedirs("static", exist_ok=True)
    resumo_chart = "static/distribuicao_confianca.png"
    try:
        total = neg_probs + neu_probs + pos_probs
        if len(total) >= 2:
            x = np.linspace(0, 100, 500)
            plt.figure(figsize=(8, 4))
            if len(neg_probs) > 1:
                plt.plot(x, gaussian_kde(neg_probs)(x), label="Negative")
            if len(neu_probs) > 1:
                plt.plot(x, gaussian_kde(neu_probs)(x), label="Neutral")
            if len(pos_probs) > 1:
                plt.plot(x, gaussian_kde(pos_probs)(x), label="Positive")
            plt.xlabel("Confiança (%)")
            plt.ylabel("Densidade")
            plt.title("Distribuição de Confiança")
            plt.legend()
            plt.tight_layout()
            plt.savefig(resumo_chart, dpi=200)
            plt.close()
    except Exception as e:
        logger.error("Erro ao gerar gráfico KDE: %s", e, exc_info=True)

    # 4️⃣ WordCloud
    wc_chart = "static/nuvem_palavras_all.png"
    try:
        wordcloud = WordCloud(width=700, height=350, background_color="white",
                              stopwords=set(STOPWORDS)).generate(" ".join(text_accum))
        plt.figure(figsize=(7, 3.5))
        plt.imshow(wordcloud, interpolation="bilinear")
        plt.axis("off")
        plt.tight_layout()
        plt.savefig(wc_chart, dpi=200)
        plt.close()
    except Exception as e:
        logger.error("Erro ao gerar WordCloud: %s", e, exc_info=True)

    logger.info("[DETAIL_ALL] Tudo concluído.")
    return render_template(
        "detail_all.html",
        posts=analysed_posts,
        resumo_chart=resumo_chart,
        wc_chart=wc_chart
    )


@app.route("/gerar_relatorio", methods=["POST"])
def gerar_relatorio():
    post_ids = session.get("post_ids")
    if not post_ids:
        flash("Não há dados disponíveis para gerar relatório.", "warning")
        return redirect(url_for("home"))

    if not CONTAINER_ENDPOINT_SAS:
        logger.error("CONTAINER_ENDPOINT_SAS inválido ou ausente no gerar_relatorio.")
        flash("CONTAINER_ENDPOINT_SAS inválido ou ausente.", "danger")
        return redirect(url_for("home"))

    # 1) Buscar dados completos do Cosmos
    try:
        posts = get_posts_from_cosmos(post_ids)
    except Exception as e:
        logger.error(f"Erro ao buscar posts do Cosmos em gerar_relatorio: {e}", exc_info=True)
        flash(f"Erro ao buscar posts do Cosmos: {e}", "danger")
        return redirect(url_for("home"))

    timestamp = datetime.utcnow().strftime('%Y%m%d_%H%M%S')
    df = pd.DataFrame(posts)
    local_csv_name = f"relatorio_{timestamp}.csv"
    df.to_csv(local_csv_name, index=False, encoding="utf-8")

    try:
        # Separar base e token
        parts = CONTAINER_ENDPOINT_SAS.split('?', 1)
        if len(parts) != 2:
            raise ValueError("Formato inválido de CONTAINER_ENDPOINT_SAS")
        sas_url_base, sas_token = parts
        # Upload CSV
        blob_url = f"{sas_url_base}/{local_csv_name}?{sas_token}"
        blob_client = BlobClient.from_blob_url(blob_url)
        with open(local_csv_name, "rb") as data:
            blob_client.upload_blob(data, overwrite=True, content_settings=ContentSettings(
                content_type="text/csv",
                content_disposition="inline"
            ))
        # Upload de gráficos, se existirem
        candidatos = [
            ("static/distribuicao_confianca.png", f"distribuicao_confianca_{timestamp}.png"),
            ("static/nuvem_palavras_all.png", f"nuvem_palavras_all_{timestamp}.png")
        ]
        for local_path, target_name in candidatos:
            if os.path.exists(local_path):
                chart_url = f"{sas_url_base}/{target_name}?{sas_token}"
                chart_client = BlobClient.from_blob_url(chart_url)
                with open(local_path, "rb") as chart_file:
                    chart_client.upload_blob(chart_file, overwrite=True, content_settings=ContentSettings(
                        content_type="image/png",
                        content_disposition="inline"
                    ))
        flash("Relatório e gráficos enviados com sucesso.", "success")
    except Exception as e:
        logger.error("Erro ao enviar para Azure Blob Storage: %s", e, exc_info=True)
        flash(f"Erro ao enviar para Azure Blob Storage: {e}", "danger")

    return redirect(url_for("home"))


@app.route("/listar_ficheiros", methods=["GET"])
def listar_ficheiros():
    if not CONTAINER_ENDPOINT_SAS:
        flash("CONTAINER_ENDPOINT_SAS inválido ou ausente.", "danger")
        return redirect(url_for("home"))
    try:
        container_client = ContainerClient.from_container_url(CONTAINER_ENDPOINT_SAS)
        blobs = list(container_client.list_blobs())
        # Ordenar por timestamp extraído do nome, se houver padrão
        def extrai_ts(nome):
            m = re.search(r'_(\d{8}_\d{6})', nome)
            return m.group(1) if m else ""
        ficheiros = sorted(
            [blob.name for blob in blobs],
            key=lambda name: extrai_ts(name),
            reverse=True
        )
        sas_parts = CONTAINER_ENDPOINT_SAS.split('?', 1)
        sas_base = sas_parts[0]
        sas_token = sas_parts[1] if len(sas_parts) > 1 else ""
        return render_template("ficheiros.html", ficheiros=ficheiros, sas_base=sas_base, sas_token=sas_token)
    except Exception as e:
        logger.error("Erro ao listar ficheiros: %s", e, exc_info=True)
        flash(f"Erro ao listar ficheiros: {e}", "danger")
        return redirect(url_for("home"))

@app.route("/apagar_ficheiro", methods=["POST"])
def apagar_ficheiro():
    if not CONTAINER_ENDPOINT_SAS:
        flash("CONTAINER_ENDPOINT_SAS inválido ou ausente.", "danger")
        return redirect(url_for("listar_ficheiros"))

    ficheiro = request.form.get("ficheiro")
    if not ficheiro:
        flash("Nenhum ficheiro especificado para apagar.", "warning")
        return redirect(url_for("listar_ficheiros"))

    try:
        sas_parts = CONTAINER_ENDPOINT_SAS.split('?', 1)
        sas_base = sas_parts[0]
        sas_token = sas_parts[1] if len(sas_parts) > 1 else ""

        blob_url = f"{sas_base}/{ficheiro}?{sas_token}"
        blob_client = BlobClient.from_blob_url(blob_url)

        blob_client.delete_blob()
        flash(f"Ficheiro '{ficheiro}' apagado com sucesso.", "success")
    except Exception as e:
        logger.error(f"Erro ao apagar ficheiro '{ficheiro}': {e}", exc_info=True)
        flash(f"Erro ao apagar ficheiro: {e}", "danger")

    return redirect(url_for("listar_ficheiros"))


if __name__ == "__main__":
    # Logs de variáveis de ambiente para debug inicial
    logger.info(f"Startup: FUNCTION_URL = {FUNCTION_URL}")
    logger.info(f"Startup: GET_POSTS_FUNCTION_URL = {GET_POSTS_FUNCTION_URL}")
    logger.info(f"Startup: CONTAINER_ENDPOINT_SAS = {CONTAINER_ENDPOINT_SAS}")
    # Em produção, substitua app.run por servidor WSGI adequado
    app.run(host="0.0.0.0", port=int(os.getenv("PORT", 5000)))