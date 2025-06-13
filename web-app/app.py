import os
import requests
import pandas as pd
import numpy as np
import matplotlib.pyplot as plt
from collections import Counter
from scipy.stats import gaussian_kde
from transformers import pipeline
from wordcloud import WordCloud, STOPWORDS
from flask import Flask, render_template, request, flash, redirect, url_for, session
import re
from azure.storage.blob import BlobClient, ContainerClient, ContentSettings
from datetime import datetime
import logging

# Configurar logging
logging.basicConfig(level=logging.INFO)
logger = logging.getLogger(__name__)

# Inicializa Flask
app = Flask(__name__)
app.secret_key = os.getenv("FLASK_SECRET_KEY", "dev_secret_key")

# Variáveis de ambiente esperadas
FUNCTION_URL = os.getenv("FUNCTION_URL")
CONTAINER_ENDPOINT_SAS = os.getenv("CONTAINER_ENDPOINT_SAS")

# Validações iniciais de env vars
if not FUNCTION_URL:
    logger.error("Env var FUNCTION_URL não está configurada. Defina em App Settings antes de chamar a Function.")
else:
    preview = FUNCTION_URL
    if "?" in FUNCTION_URL:
        preview = FUNCTION_URL.split("?")[0] + "?..."
    logger.info(f"FUNCTION_URL configurada: {preview}")

if not CONTAINER_ENDPOINT_SAS or "?" not in CONTAINER_ENDPOINT_SAS:
    logger.error("Env var CONTAINER_ENDPOINT_SAS ausente ou em formato inválido. Deve ser algo como "
                 "https://<account>.blob.core.windows.net/<container>?<sas-token>")

# Inicializar pipeline de análise de sentimento
try:
    classifier = pipeline("zero-shot-classification", model="facebook/bart-large-mnli")
    candidate_labels = ["negative", "neutral", "positive"]
    logger.info("Pipeline de sentiment carregado com sucesso.")
except Exception as e:
    logger.error("Erro ao carregar pipeline de sentiment.", exc_info=True)
    classifier = None
    candidate_labels = []

def fetch_posts(subreddit, sort, limit):
    """Chama a Azure Function para buscar posts do Reddit."""
    if not FUNCTION_URL:
        flash("Serviço de backend não configurado (FUNCTION_URL ausente).", "danger")
        return None

    try:
        logger.info(f"fetch_posts: chamando FUNCTION_URL={FUNCTION_URL} com params "
                    f"subreddit={subreddit}, sort={sort}, limit={limit}")
        resp = requests.get(
            FUNCTION_URL,
            params={"subreddit": subreddit, "sort": sort, "limit": limit},
            timeout=30
        )
        logger.info(f"fetch_posts: status_code={resp.status_code}")
        text_preview = resp.text[:200] + ("..." if len(resp.text) > 200 else "")
        logger.debug(f"fetch_posts: resposta text preview: {text_preview!r}")

        if resp.status_code == 404:
            flash(f"Não foi possível encontrar o recurso de backend (404). Verifique configuração.", "warning")
            return None
        resp.raise_for_status()
        data = resp.json()
        logger.info(f"fetch_posts: JSON recebido com chaves={list(data.keys())}")
        posts = data.get("posts", data)
        if posts is None:
            flash("Backend retornou conteúdo inesperado.", "warning")
            return None
        return posts
    except requests.exceptions.Timeout:
        logger.error("Timeout ao chamar a Function.", exc_info=True)
        flash("Tempo de resposta excedido ao chamar o serviço de backend.", "danger")
        return None
    except requests.exceptions.RequestException as e:
        logger.error(f"Erro ao obter posts: {e}", exc_info=True)
        flash(f"Erro ao obter posts: {e}", "danger")
        return None
    except ValueError as e:
        logger.error(f"Erro ao parsear JSON da resposta: {e}", exc_info=True)
        flash("Resposta inválida do serviço de backend.", "danger")
        return None

@app.route("/", methods=["GET"])
def home():
    session.clear()
    return render_template("index.html", posts=None)

@app.route("/search", methods=["GET"])
def search():
    subreddit = request.args.get("subreddit", "").strip()
    sort = request.args.get("sort", "hot").strip()
    limit_str = request.args.get("limit", "10").strip()

    if not subreddit:
        flash("Informe um subreddit.", "warning")
        return redirect(url_for("home"))

    try:
        limit = int(limit_str)
    except ValueError:
        flash("O campo 'Número de posts' deve ser um número inteiro.", "warning")
        return redirect(url_for("home"))

    posts = fetch_posts(subreddit, sort, limit)
    if posts is None:
        return redirect(url_for("home"))

    session["posts"] = posts
    session["search_params"] = {"subreddit": subreddit, "sort": sort, "limit": limit}
    return render_template("index.html", posts=posts, subreddit=subreddit, sort=sort, limit=limit)

@app.route("/detail_all", methods=["POST"])
def detail_all():
    posts = session.get("posts")
    if not posts:
        flash("Nenhum post disponível para análise.", "warning")
        return redirect(url_for("home"))

    if classifier is None:
        flash("Serviço de análise de sentimento indisponível.", "danger")
        return redirect(url_for("home"))

    analysed_posts = []
    os.makedirs("static", exist_ok=True)
    text_accum = []
    neg_probs, neu_probs, pos_probs = [], [], []

    for post in posts:
        input_text = post.get('selftext', "").strip() or post.get('title', "")
        try:
            sentiment = classifier(input_text, candidate_labels)
            scores = dict(zip(sentiment['labels'], sentiment['scores']))
            top_label = sentiment['labels'][0].capitalize()
            prob_top = int(sentiment['scores'][0] * 100)
        except Exception as e:
            logger.error(f"Erro na análise de sentimento para texto: {input_text[:50]!r}", exc_info=True)
            top_label = "Unknown"
            prob_top = 0
            scores = {lbl: 0.0 for lbl in candidate_labels}

        post['sentimento'] = top_label
        post['probabilidade'] = prob_top
        post['scores_raw'] = scores
        analysed_posts.append(post)

        text_accum.append(input_text)
        neg_probs.append(scores.get("negative", 0) * 100)
        neu_probs.append(scores.get("neutral", 0) * 100)
        pos_probs.append(scores.get("positive", 0) * 100)

    # Gera gráfico de densidade apenas se tivermos >=2 pontos em ao menos um conjunto
    kde_chart = None
    try:
        # Verifica se há múltiplos valores para gerar KDE
        can_kde = False
        # Checa cada lista: precisa de pelo menos 2 valores distintos ou 2 elementos?
        if len(neg_probs) > 1:
            can_kde = True
        if len(neu_probs) > 1:
            can_kde = True
        if len(pos_probs) > 1:
            can_kde = True

        if can_kde:
            x = np.linspace(0, 100, 500)
            plt.figure(figsize=(8, 4))
            plotted = False
            # Negative
            if len(neg_probs) > 1 and any(neg_probs):
                try:
                    kde_neg = gaussian_kde(neg_probs)
                    y_neg = kde_neg(x)
                    y_neg = y_neg / y_neg.sum() * 100
                    plt.plot(x, y_neg, label="Negative", linewidth=2)
                    plt.fill_between(x, y_neg, alpha=0.2)
                    plotted = True
                except Exception as e:
                    logger.warning("Não foi possível gerar KDE para negative.", exc_info=True)
            # Neutral
            if len(neu_probs) > 1 and any(neu_probs):
                try:
                    kde_neu = gaussian_kde(neu_probs)
                    y_neu = kde_neu(x)
                    y_neu = y_neu / y_neu.sum() * 100
                    plt.plot(x, y_neu, label="Neutral", linewidth=2)
                    plt.fill_between(x, y_neu, alpha=0.2)
                    plotted = True
                except Exception as e:
                    logger.warning("Não foi possível gerar KDE para neutral.", exc_info=True)
            # Positive
            if len(pos_probs) > 1 and any(pos_probs):
                try:
                    kde_pos = gaussian_kde(pos_probs)
                    y_pos = kde_pos(x)
                    y_pos = y_pos / y_pos.sum() * 100
                    plt.plot(x, y_pos, label="Positive", linewidth=2)
                    plt.fill_between(x, y_pos, alpha=0.2)
                    plotted = True
                except Exception as e:
                    logger.warning("Não foi possível gerar KDE para positive.", exc_info=True)

            if plotted:
                plt.xlabel("Confiança da Análise (%)")
                plt.ylabel("Distribuição Normalizada (%)")
                plt.title("Distribuição e Densidade de Confiança por Sentimento")
                plt.legend()
                plt.tight_layout()
                kde_chart = "static/distribuicao_confianca.png"
                plt.savefig(kde_chart, dpi=200)
                plt.close()
            else:
                logger.info("Nenhum KDE plotado: dados insuficientes ou todos zero.")
                kde_chart = None
        else:
            logger.info("Dados insuficientes para KDE (menos de 2 elementos em cada série). Pulando geração de densidade.")
    except Exception as e:
        logger.error("Erro ao gerar gráfico de densidade.", exc_info=True)
        kde_chart = None

    # Gera wordcloud
    wc_chart = None
    try:
        if text_accum:
            wordcloud = WordCloud(width=700, height=350, background_color="white",
                                  stopwords=set(STOPWORDS)).generate(" ".join(text_accum))
            plt.figure(figsize=(7, 3.5))
            plt.imshow(wordcloud, interpolation="bilinear")
            plt.axis("off")
            plt.tight_layout()
            wc_chart = "static/nuvem_palavras_all.png"
            plt.savefig(wc_chart, dpi=200)
            plt.close()
        else:
            logger.info("Nenhum texto para WordCloud.")
    except Exception as e:
        logger.error("Erro ao gerar wordcloud.", exc_info=True)
        wc_chart = None

    return render_template("detail_all.html", posts=analysed_posts,
                           resumo_chart=kde_chart,
                           wc_chart=wc_chart,
                           # gantt_chart era redundante, podemos reutilizar resumo_chart ou outro
                           gantt_chart=kde_chart)

@app.route("/gerar_relatorio", methods=["POST"])
def gerar_relatorio():
    posts = session.get("posts")
    if not posts:
        flash("Não há dados disponíveis para gerar relatório.", "warning")
        return redirect(url_for("home"))

    if not CONTAINER_ENDPOINT_SAS or "?" not in CONTAINER_ENDPOINT_SAS:
        logger.error("CONTAINER_ENDPOINT_SAS inválido ou ausente no gerar_relatorio.")
        flash("Configuração de Blob SAS inválida.", "danger")
        return redirect(url_for("home"))

    timestamp = datetime.utcnow().strftime('%Y%m%d_%H%M%S')
    df = pd.DataFrame(posts)
    local_csv_name = f"relatorio_{timestamp}.csv"
    try:
        df.to_csv(local_csv_name, index=False, encoding="utf-8")
    except Exception as e:
        logger.error("Erro ao salvar CSV localmente.", exc_info=True)
        flash("Erro ao criar relatório local.", "danger")
        return redirect(url_for("home"))

    charts = {}
    possible_kde = "static/distribuicao_confianca.png"
    possible_wc = "static/nuvem_palavras_all.png"
    if os.path.isfile(possible_kde):
        charts[f"distribuicao_confianca_{timestamp}.png"] = possible_kde
    if os.path.isfile(possible_wc):
        charts[f"nuvem_palavras_all_{timestamp}.png"] = possible_wc

    try:
        sas_url_base = CONTAINER_ENDPOINT_SAS.split('?')[0]
        sas_token = CONTAINER_ENDPOINT_SAS.split('?')[1]

        # Upload CSV
        blob_url = f"{sas_url_base}/{local_csv_name}?{sas_token}"
        logger.info(f"Upload CSV para blob: {blob_url}")
        blob_client = BlobClient.from_blob_url(blob_url)
        with open(local_csv_name, "rb") as data:
            blob_client.upload_blob(data, overwrite=True, content_settings=ContentSettings(
                content_type="text/csv",
                content_disposition="inline"
            ))

        # Upload charts, se existirem
        for filename, local_path in charts.items():
            blob_chart_url = f"{sas_url_base}/{filename}?{sas_token}"
            logger.info(f"Upload chart para blob: {blob_chart_url}")
            chart_client = BlobClient.from_blob_url(blob_chart_url)
            with open(local_path, "rb") as chart_file:
                chart_client.upload_blob(chart_file, overwrite=True, content_settings=ContentSettings(
                    content_type="image/png",
                    content_disposition="inline"
                ))

        flash("Relatório e gráficos enviados com sucesso.", "success")
    except Exception as e:
        logger.error("Erro ao enviar para Azure Blob Storage.", exc_info=True)
        flash("Erro ao enviar para Azure Blob Storage.", "danger")

    return redirect(url_for("home"))

@app.route("/listar_ficheiros", methods=["GET"])
def listar_ficheiros():
    if not CONTAINER_ENDPOINT_SAS or "?" not in CONTAINER_ENDPOINT_SAS:
        logger.error("CONTAINER_ENDPOINT_SAS inválido ou ausente no listar_ficheiros.")
        flash("Configuração de Blob SAS inválida.", "danger")
        return redirect(url_for("home"))

    try:
        sas_url = CONTAINER_ENDPOINT_SAS
        container_client = ContainerClient.from_container_url(sas_url)
        blobs = list(container_client.list_blobs())
        logger.info(f"Encontrados {len(blobs)} blobs no container.")

        ficheiros = [blob.name for blob in blobs]
        ficheiros = sorted(
            ficheiros,
            key=lambda name: re.search(r'_(\d{8}_\d{6})', name).group(1) if re.search(r'_(\d{8}_\d{6})', name) else '',
            reverse=True
        )
        sas_base = sas_url.split('?')[0]
        sas_token = sas_url.split('?')[1]
        return render_template("ficheiros.html", ficheiros=ficheiros, sas_base=sas_base, sas_token=sas_token)
    except Exception as e:
        logger.error("Erro ao listar ficheiros no Blob Storage.", exc_info=True)
        flash("Erro ao listar ficheiros: verifique configuração de Blob SAS.", "danger")
        return redirect(url_for("home"))

if __name__ == "__main__":
    app.run(host="0.0.0.0", port=int(os.getenv("PORT", 5000)))
