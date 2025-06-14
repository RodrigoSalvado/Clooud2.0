import os
import requests
import pandas as pd
import numpy as np
import matplotlib.pyplot as plt
from scipy.stats import gaussian_kde
from transformers import pipeline
from wordcloud import WordCloud, STOPWORDS
from flask import Flask, render_template, request, flash, redirect, url_for, session
import re
from azure.storage.blob import BlobClient, ContainerClient, ContentSettings
from datetime import datetime
import logging

# Configuração de logging
logging.basicConfig(level=logging.INFO)
logger = logging.getLogger(__name__)

app = Flask(__name__)
app.secret_key = os.getenv("FLASK_SECRET_KEY", "dev_secret_key")

# Variáveis de ambiente esperadas
# FUNCTION_URL: URL da Azure Function que ingere do Reddit e insere/atualiza no Cosmos, retorna lista de posts
FUNCTION_URL = os.getenv("FUNCTION_URL")
# GET_POSTS_FUNCTION_URL: URL da Azure Function que, dado ?ids=id1,id2,..., faz read do Cosmos e retorna {"posts": [...]}
GET_POSTS_FUNCTION_URL = os.getenv("GET_POSTS_FUNCTION_URL")
# SAS do container para relatórios/gráficos
CONTAINER_ENDPOINT_SAS = os.getenv("CONTAINER_ENDPOINT_SAS")

# Inicializar pipeline de análise de sentimento
try:
    classifier = pipeline("zero-shot-classification", model="facebook/bart-large-mnli")
    candidate_labels = ["negative", "neutral", "positive"]
    logger.info("Pipeline de sentiment carregado com sucesso.")
except Exception as e:
    logger.error("Falha ao inicializar pipeline de sentimento: %s", e, exc_info=True)
    classifier = None
    candidate_labels = []

def fetch_and_ingest_posts(subreddit, sort, limit):
    """
    Chama a função de ingestão do Reddit (FUNCTION_URL), retorna lista de posts (cada post dict com 'id', 'subreddit', 'title', etc).
    Essa função faz o upsert no Cosmos e devolve os dados recém-ingestados do Reddit.
    """
    if not FUNCTION_URL:
        raise RuntimeError("FUNCTION_URL não está configurado")
    resp = requests.get(
        FUNCTION_URL,
        params={"subreddit": subreddit, "sort": sort, "limit": limit},
        timeout=30
    )
    resp.raise_for_status()
    data = resp.json()
    return data.get("posts", data)

def get_posts_from_cosmos(ids: list[str]):
    """
    Chama GET_POSTS_FUNCTION_URL com query param 'ids', retorna lista de posts sanitizados do Cosmos.
    Espera que a função responda {"posts": [...]}, onde cada elemento tem pelo menos id, subreddit, title, selftext, url.
    """
    if not GET_POSTS_FUNCTION_URL:
        raise RuntimeError("GET_POSTS_FUNCTION_URL não está configurado")
    if not ids:
        return []
    # Monta query param: ids comma-separated
    ids_param = ",".join(ids)
    resp = requests.get(GET_POSTS_FUNCTION_URL, params={"ids": ids_param}, timeout=30)
    resp.raise_for_status()
    data = resp.json()
    return data.get("posts", data)

@app.route("/", methods=["GET"])
def home():
    # Ao entrar na home, limpamos sessão de pesquisas anteriores
    session.pop("post_ids", None)
    session.pop("search_params", None)
    return render_template("index.html", posts=None)

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
    except Exception as e:
        logger.error(f"Erro ao obter/ingerir posts do Reddit: {e}", exc_info=True)
        flash(f"Erro ao obter posts do Reddit: {e}", "danger")
        return redirect(url_for("home"))

    # 2) Extrai apenas os IDs
    post_ids = []
    for p in posts:
        pid = p.get("id")
        if pid:
            post_ids.append(pid)
    # Se nenhum ID, informar
    if not post_ids:
        flash("Nenhum post válido retornado da ingestão.", "warning")
        return redirect(url_for("home"))

    # 3) Armazena IDs e parâmetros de pesquisa na sessão
    session["post_ids"] = post_ids
    session["search_params"] = {"subreddit": subreddit, "sort": sort, "limit": limit}

    # 4) Buscar dados completos via Cosmos (GET_POSTS_FUNCTION_URL)
    try:
        cosmos_posts = get_posts_from_cosmos(post_ids)
    except Exception as e:
        logger.error(f"Erro ao buscar posts do Cosmos: {e}", exc_info=True)
        flash(f"Erro ao buscar posts do Cosmos: {e}", "danger")
        # Mesmo que falhe, podemos mostrar versão bruta do ingest (posts), mas ideal avisar
        cosmos_posts = posts

    # 5) Renderiza a página com os posts completos
    return render_template("index.html", posts=cosmos_posts, subreddit=subreddit, sort=sort, limit=limit)

@app.route("/detail_all", methods=["POST"])
def detail_all():
    post_ids = session.get("post_ids")
    if not post_ids:
        flash("Nenhum post disponível para análise.", "warning")
        return redirect(url_for("home"))

    if classifier is None:
        flash("Pipeline de sentimento não está disponível.", "danger")
        return redirect(url_for("home"))

    # 1) Obter dados do Cosmos para cada ID
    try:
        posts = get_posts_from_cosmos(post_ids)
    except Exception as e:
        logger.error(f"Erro ao buscar posts do Cosmos em detail_all: {e}", exc_info=True)
        flash(f"Erro ao buscar posts do Cosmos: {e}", "danger")
        return redirect(url_for("home"))

    analysed_posts = []
    os.makedirs("static", exist_ok=True)
    text_accum = []
    neg_probs, neu_probs, pos_probs = [], [], []

    # Analisar sentimento em cada post
    for post in posts:
        input_text = post.get('selftext', '').strip() or post.get('title', '').strip()
        if not input_text:
            post['sentimento'] = 'Unknown'
            post['probabilidade'] = 0
            post['scores_raw'] = {}
        else:
            try:
                sentiment = classifier(input_text, candidate_labels)
                scores = dict(zip(sentiment['labels'], sentiment['scores']))
                top_label = sentiment['labels'][0].capitalize()
                post['sentimento'] = top_label
                post['probabilidade'] = int(sentiment['scores'][0] * 100)
                post['scores_raw'] = scores
                neg_probs.append(scores.get("negative", 0) * 100)
                neu_probs.append(scores.get("neutral", 0) * 100)
                pos_probs.append(scores.get("positive", 0) * 100)
                text_accum.append(input_text)
            except Exception as e:
                logger.error(f"Erro ao analisar sentimento do post '{post.get('title')[:30]}...': {e}", exc_info=True)
                post['sentimento'] = 'Error'
                post['probabilidade'] = 0
                post['scores_raw'] = {}
        analysed_posts.append(post)

    # Geração de gráficos como antes...
    resumo_chart = None
    wc_chart = None
    # ... (mesmo código de KDE e WordCloud)
    try:
        total_values = neg_probs + neu_probs + pos_probs
        if len(total_values) >= 2:
            x = np.linspace(0, 100, 500)
            plt.figure(figsize=(8, 4))
            plotted = False
            if len(neg_probs) > 1 and any(neg_probs):
                try:
                    kde_neg = gaussian_kde(neg_probs)
                    y_neg = kde_neg(x)
                    y_neg = y_neg / y_neg.sum() * 100
                    plt.plot(x, y_neg, label="Negative", linewidth=2)
                    plt.fill_between(x, y_neg, alpha=0.2)
                    plotted = True
                except Exception as e:
                    logger.warning("Falha ao gerar KDE para negativos: %s", e)
            if len(neu_probs) > 1 and any(neu_probs):
                try:
                    kde_neu = gaussian_kde(neu_probs)
                    y_neu = kde_neu(x)
                    y_neu = y_neu / y_neu.sum() * 100
                    plt.plot(x, y_neu, label="Neutral", linewidth=2)
                    plt.fill_between(x, y_neu, alpha=0.2)
                    plotted = True
                except Exception as e:
                    logger.warning("Falha ao gerar KDE para neutros: %s", e)
            if len(pos_probs) > 1 and any(pos_probs):
                try:
                    kde_pos = gaussian_kde(pos_probs)
                    y_pos = kde_pos(x)
                    y_pos = y_pos / y_pos.sum() * 100
                    plt.plot(x, y_pos, label="Positive", linewidth=2)
                    plt.fill_between(x, y_pos, alpha=0.2)
                    plotted = True
                except Exception as e:
                    logger.warning("Falha ao gerar KDE para positivos: %s", e)
            if plotted:
                plt.xlabel("Confiança da Análise (%)")
                plt.ylabel("Distribuição Normalizada (%)")
                plt.title("Distribuição e Densidade de Confiança por Sentimento")
                plt.legend()
                plt.tight_layout()
                resumo_chart = "static/distribuicao_confianca.png"
                plt.savefig(resumo_chart, dpi=200)
            plt.close()
    except Exception as e:
        logger.error("Erro ao gerar gráfico de densidade: %s", e, exc_info=True)

    try:
        full_text = " ".join(text_accum).strip()
        words = re.findall(r"\w+", full_text)
        filtered_words = [w for w in words if w.lower() not in STOPWORDS]
        if filtered_words:
            wordcloud = WordCloud(width=700, height=350, background_color="white",
                                  stopwords=set(STOPWORDS)).generate(" ".join(filtered_words))
            plt.figure(figsize=(7, 3.5))
            plt.imshow(wordcloud, interpolation="bilinear")
            plt.axis("off")
            plt.tight_layout()
            wc_chart = "static/nuvem_palavras_all.png"
            plt.savefig(wc_chart, dpi=200)
            plt.close()
    except Exception as e:
        logger.error("Erro ao gerar wordcloud: %s", e, exc_info=True)

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


if __name__ == "__main__":
    # Em produção, substitua app.run por servidor WSGI adequado
    logger.info(f"Valor de CONTAINER_ENDPOINT_SAS no startup: {CONTAINER_ENDPOINT_SAS}")
    logger.info(f"Valor de GET_POSTS_FUNCTION_URL no startup: {GET_POSTS_FUNCTION_URL}")
    app.run(host="0.0.0.0", port=5000)
