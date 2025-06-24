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
    import seaborn as sns
    from wordcloud import WordCloud, STOPWORDS
    import matplotlib.pyplot as plt

    # --- 0️⃣ Ambiente Cosmos
    cosmos_client = CosmosClient(COSMOS_ENDPOINT, COSMOS_KEY)
    db_client = cosmos_client.get_database_client(COSMOS_DATABASE)
    cont_client = db_client.get_container_client(COSMOS_CONTAINER)

    # --- 1️⃣ IDs
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

    # --- 2️⃣ Buscar posts do Cosmos
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

    # --- 3️⃣ Detectar + traduzir se necessário, guardar text_to_analyse no Cosmos se não existir
    analysed_posts = []
    texts = []
    posts_index = []
    neg_probs, neu_probs, pos_probs = [], [], []
    text_accum = []

    # Credenciais Translator
    TRANSLATOR_KEY = os.getenv("TRANSLATOR_KEY")
    TRANSLATOR_ENDPOINT = os.getenv("TRANSLATOR_ENDPOINT")
    TRANSLATOR_REGION = os.getenv("TRANSLATOR_REGION", "westeurope")

    def detect_language(text):
        url = TRANSLATOR_ENDPOINT + "/detect"
        headers = {
            'Ocp-Apim-Subscription-Key': TRANSLATOR_KEY,
            'Ocp-Apim-Subscription-Region': TRANSLATOR_REGION,
            'Content-Type': 'application/json'
        }
        body = [{'text': text}]
        resp = requests.post(url, params={'api-version': '3.0'}, headers=headers, json=body)
        resp.raise_for_status()
        return resp.json()[0]['language']

    def translate_to_english(text, from_lang=None):
        url = TRANSLATOR_ENDPOINT + "/translate"
        headers = {
            'Ocp-Apim-Subscription-Key': TRANSLATOR_KEY,
            'Ocp-Apim-Subscription-Region': TRANSLATOR_REGION,
            'Content-Type': 'application/json'
        }
        params = {'api-version': '3.0', 'to': ['en']}
        if from_lang:
            params['from'] = from_lang
        body = [{'text': text}]
        resp = requests.post(url, params=params, headers=headers, json=body)
        resp.raise_for_status()
        return resp.json()[0]['translations'][0]['text']

    for idx, post in enumerate(posts):
        # 1️⃣ Usa text_to_analyse se já existir
        snippet = post.get('text_to_analyse', '').strip()

        # 2️⃣ Caso não exista, detecta + traduz e guarda no Cosmos
        if not snippet:
            base_text = post.get('selftext', '').strip() or post.get('title', '').strip()
            if base_text:
                try:
                    detected = detect_language(base_text)
                    snippet = translate_to_english(base_text, from_lang=detected)
                    # Guardar de volta no Cosmos
                    full_id = post.get('id') or post.get('full_id')
                    if full_id and "_" in full_id:
                        query = f"SELECT * FROM c WHERE c.id = '{full_id}'"
                        items = list(cont_client.query_items(query=query, enable_cross_partition_query=True))
                        if items:
                            item = items[0]
                            item["text_to_analyse"] = snippet
                            cont_client.replace_item(item=item['id'], body=item)
                            logger.info(f"✅ text_to_analyse guardado no Cosmos: {full_id}")
                except Exception as e:
                    logger.error(f"Erro ao traduzir/detectar idioma: {e}", exc_info=True)
                    snippet = base_text  # fallback

        # 3️⃣ Se ainda assim nada, pula sentimento
        if snippet:
            snippet = snippet[:512]
            texts.append(snippet)
            posts_index.append(idx)
        else:
            post['sentimento'] = 'Unknown'
            post['probabilidade'] = 0
            analysed_posts.append(post)

    # --- 4️⃣ Sentimento por batch
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

    # --- 5️⃣ Guardar sentimento + confiabilidade no Cosmos
    try:
        for post in analysed_posts:
            full_id = post.get('id') or post.get('full_id')
            if not full_id or "_" not in full_id:
                continue

            query = f"SELECT * FROM c WHERE c.id = '{full_id}'"
            items = list(cont_client.query_items(query=query, enable_cross_partition_query=True))
            if not items:
                logger.warning(f"❌ Item não encontrado no Cosmos: {full_id}")
                continue

            item = items[0]
            item["sentimento"] = post['sentimento']
            item["confiabilidade"] = round(post['probabilidade'] / 100, 4)
            cont_client.replace_item(item=item['id'], body=item)
            logger.info(f"✅ Sentimento actualizado: {full_id}")

    except Exception as e:
        logger.error("Erro ao actualizar sentimento no Cosmos: %s", e, exc_info=True)
        flash(f"Erro ao actualizar sentimento no Cosmos: {e}", "danger")

    # --- 6️⃣ Gráfico KDE + WordCloud
    os.makedirs("static", exist_ok=True)
    resumo_chart = "static/distribuicao_confianca.png"
    wc_chart = "static/nuvem_palavras_all.png"

    try:
        # --- Dados para barras
        categorias = []
        counts = []
        avg_probs = []

        if neg_probs:
            categorias.append("Negative")
            counts.append(len(neg_probs))
            avg_probs.append(np.mean(neg_probs))
        if neu_probs:
            categorias.append("Neutral")
            counts.append(len(neu_probs))
            avg_probs.append(np.mean(neu_probs))
        if pos_probs:
            categorias.append("Positive")
            counts.append(len(pos_probs))
            avg_probs.append(np.mean(pos_probs))

        if categorias:
            plt.figure(figsize=(8, 5))
            bars = plt.bar(categorias, counts, color=['red', 'grey', 'green'][:len(categorias)])

            # Limite superior para texto não colidir
            plt.ylim(0, max(counts) * 1.3)

            # Anota cada barra
            for bar, avg_conf in zip(bars, avg_probs):
                height = bar.get_height()
                plt.text(
                    bar.get_x() + bar.get_width() / 2,
                    height + 0.1,
                    f"Média Confiança: {avg_conf:.1f}%",
                    ha='center',
                    va='bottom',
                    fontsize=10
                )

            plt.xlabel("Categoria de Sentimento")
            plt.ylabel("Número de Posts")
            plt.title("Número de Posts e Média de Confiança por Categoria")
            plt.tight_layout()
            plt.savefig(resumo_chart, dpi=200)
            plt.close()
    except Exception as e:
        logger.error("Erro ao gerar gráfico de barras resumo: %s", e, exc_info=True)


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

    logger.info("[DETAIL_ALL] Tudo concluído com Translator.")
    return render_template(
        "detail_all.html",
        posts=analysed_posts,
        resumo_chart=resumo_chart,
        wc_chart=wc_chart
    )


@app.route("/gerar_relatorio", methods=["POST"])
def gerar_relatorio():
    if not CONTAINER_ENDPOINT_SAS:
        logger.error("CONTAINER_ENDPOINT_SAS inválido ou ausente no gerar_relatorio.")
        flash("CONTAINER_ENDPOINT_SAS inválido ou ausente.", "danger")
        return redirect(url_for("home"))

    timestamp = datetime.utcnow().strftime('%Y%m%d_%H%M%S')

    try:
        # Separar base e token
        parts = CONTAINER_ENDPOINT_SAS.split('?', 1)
        if len(parts) != 2:
            raise ValueError("Formato inválido de CONTAINER_ENDPOINT_SAS")
        sas_url_base, sas_token = parts

        # Upload apenas dos gráficos
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
        flash("Gráficos enviados com sucesso para o Blob Storage.", "success")
    except Exception as e:
        logger.error("Erro ao enviar gráficos para Azure Blob Storage: %s", e, exc_info=True)
        flash(f"Erro ao enviar gráficos para Azure Blob Storage: {e}", "danger")

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