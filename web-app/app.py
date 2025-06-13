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
from azure.storage.blob import BlobServiceClient, BlobClient, ContainerClient, ContentSettings
from datetime import datetime
from urllib.parse import urlparse


app = Flask(__name__)
app.secret_key = os.getenv("FLASK_SECRET_KEY", "dev_secret_key")
FUNCTION_URL = os.getenv("FUNCTION_URL")
CONTAINER_ENDPOINT_SAS = os.getenv("CONTAINER_ENDPOINT_SAS")

# Inicializar pipeline de análise de sentimento
classifier = pipeline("zero-shot-classification", model="facebook/bart-large-mnli")
candidate_labels = ["negative", "neutral", "positive"]

import logging
logger = logging.getLogger(__name__)

def fetch_posts(subreddit, sort, limit):
    try:
        logger.info(f"fetch_posts: FUNCTION_URL={FUNCTION_URL}, params={{subreddit:{subreddit},sort:{sort},limit:{limit}}}")
        resp = requests.get(
            FUNCTION_URL,
            params={"subreddit": subreddit, "sort": sort, "limit": limit},
            timeout=30
        )
        logger.info(f"fetch_posts: status_code={resp.status_code}, text_preview={resp.text[:200]!r}")
        resp.raise_for_status()
        data = resp.json()
        logger.info(f"fetch_posts: JSON recebido keys={list(data.keys())}")
        return data.get("posts", data)
    except Exception as e:
        logger.error(f"Erro ao obter posts: {e}", exc_info=True)
        flash(f"Erro ao obter posts: {e}", "danger")
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

    analysed_posts = []
    os.makedirs("static", exist_ok=True)
    text_accum = []
    neg_probs, neu_probs, pos_probs = [], [], []

    for post in posts:
        input_text = post['selftext'] if post['selftext'].strip() else post['title']
        sentiment = classifier(input_text, candidate_labels)
        scores = dict(zip(sentiment['labels'], sentiment['scores']))
        top_sentiment = sentiment['labels'][0].capitalize()
        post['sentimento'] = top_sentiment
        post['probabilidade'] = int(sentiment['scores'][0] * 100)
        post['scores_raw'] = scores
        analysed_posts.append(post)
        text_accum.append(input_text)
        neg_probs.append(scores.get("negative", 0) * 100)
        neu_probs.append(scores.get("neutral", 0) * 100)
        pos_probs.append(scores.get("positive", 0) * 100)

    x = np.linspace(0, 100, 500)
    plt.figure(figsize=(8, 4))

    if any(neg_probs):
        kde_neg = gaussian_kde(neg_probs)
        y_neg = kde_neg(x)
        y_neg = y_neg / y_neg.sum() * 100
        plt.plot(x, y_neg, label="Negative", color="crimson", linewidth=2)
        plt.fill_between(x, y_neg, alpha=0.2, color="crimson")

    if any(neu_probs):
        kde_neu = gaussian_kde(neu_probs)
        y_neu = kde_neu(x)
        y_neu = y_neu / y_neu.sum() * 100
        plt.plot(x, y_neu, label="Neutral", color="orange", linewidth=2)
        plt.fill_between(x, y_neu, alpha=0.2, color="orange")

    if any(pos_probs):
        kde_pos = gaussian_kde(pos_probs)
        y_pos = kde_pos(x)
        y_pos = y_pos / y_pos.sum() * 100
        plt.plot(x, y_pos, label="Positive", color="mediumseagreen", linewidth=2)
        plt.fill_between(x, y_pos, alpha=0.2, color="mediumseagreen")

    plt.xlabel("Confiança da Análise (%)")
    plt.ylabel("Distribuição Normalizada (%)")
    plt.title("Distribuição e Densidade de Confiança por Sentimento")
    plt.legend()
    plt.tight_layout()
    kde_chart = "static/distribuicao_confianca.png"
    plt.savefig(kde_chart, dpi=200)
    plt.close()

    wordcloud = WordCloud(width=700, height=350, background_color="white",
                          stopwords=set(STOPWORDS)).generate(" ".join(text_accum))
    plt.figure(figsize=(7, 3.5))
    plt.imshow(wordcloud, interpolation="bilinear")
    plt.axis("off")
    plt.tight_layout()
    wc_chart = "static/nuvem_palavras_all.png"
    plt.savefig(wc_chart, dpi=200)
    plt.close()

    return render_template("detail_all.html", posts=analysed_posts,
                           resumo_chart=kde_chart,
                           wc_chart=wc_chart,
                           gantt_chart=kde_chart)

@app.route("/gerar_relatorio", methods=["POST"])
def gerar_relatorio():
    posts = session.get("posts")
    if not posts:
        flash("Não há dados disponíveis para gerar relatório.", "warning")
        return redirect(url_for("home"))

    timestamp = datetime.utcnow().strftime('%Y%m%d_%H%M%S')
    df = pd.DataFrame(posts)
    local_csv_name = f"relatorio_{timestamp}.csv"
    df.to_csv(local_csv_name, index=False, encoding="utf-8")

    charts = {
        f"distribuicao_confianca_{timestamp}.png": "static/distribuicao_confianca.png",
        f"nuvem_palavras_all_{timestamp}.png": "static/nuvem_palavras_all.png"
    }

    try:
        sas_url_base = CONTAINER_ENDPOINT_SAS.split('?')[0]
        sas_token = CONTAINER_ENDPOINT_SAS.split('?')[1]

        blob_url = f"{sas_url_base}/{local_csv_name}?{sas_token}"
        blob_client = BlobClient.from_blob_url(blob_url)
        with open(local_csv_name, "rb") as data:
            blob_client.upload_blob(data, overwrite=True, content_settings=ContentSettings(
                content_type="text/csv",
                content_disposition="inline"
            ))

        for filename, local_path in charts.items():
            chart_url = f"{sas_url_base}/{filename}?{sas_token}"
            chart_client = BlobClient.from_blob_url(chart_url)
            with open(local_path, "rb") as chart_file:
                chart_client.upload_blob(chart_file, overwrite=True, content_settings=ContentSettings(
                    content_type="image/png",
                    content_disposition="inline"
                ))

        flash("Relatório e gráficos enviados com sucesso com identificador partilhado.", "success")

    except Exception as e:
        flash(f"Erro ao enviar para Azure Blob Storage: {str(e)}", "danger")

    return redirect(url_for("home"))

@app.route("/listar_ficheiros", methods=["GET"])
def listar_ficheiros():
    try:
        sas_url = CONTAINER_ENDPOINT_SAS

        container_client = ContainerClient.from_container_url(sas_url)
        blobs = list(container_client.list_blobs())

        ficheiros = sorted(
            [blob.name for blob in blobs],
            key=lambda name: re.search(r'_(\d{8}_\d{6})', name).group(1) if re.search(r'_(\d{8}_\d{6})', name) else '',
            reverse=True
        )

        return render_template("ficheiros.html", ficheiros=ficheiros, sas_base=sas_url.split('?')[0], sas_token=sas_url.split('?')[1])

    except Exception as e:
        flash(f"Erro ao listar ficheiros: {str(e)}", "danger")
        return redirect(url_for("home"))

if __name__ == "__main__":
    app.run(host="0.0.0.0", port=5000)
