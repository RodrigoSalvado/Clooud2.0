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
FUNCTION_URL = os.getenv("FUNCTION_URL")
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

def fetch_posts(subreddit, sort, limit):
    if not FUNCTION_URL:
        flash("FUNCTION_URL não está configurado.", "danger")
        logger.error("FUNCTION_URL ausente")
        return None
    try:
        logger.info(f"fetch_posts: chamando FUNCTION_URL={FUNCTION_URL} com params subreddit={subreddit}, sort={sort}, limit={limit}")
        resp = requests.get(
            FUNCTION_URL,
            params={"subreddit": subreddit, "sort": sort, "limit": limit},
            timeout=30
        )
        logger.info(f"fetch_posts: status_code={resp.status_code}, texto_inicio={resp.text[:200]!r}")
        resp.raise_for_status()
        data = resp.json()
        logger.info(f"fetch_posts: JSON recebido com chaves={list(data.keys())}")
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

    if not subreddit:
        flash("Informe o nome do subreddit.", "warning")
        return redirect(url_for("home"))
    try:
        limit = int(limit_str)
    except ValueError:
        flash("O campo 'Número de posts' deve ser um número inteiro.", "warning")
        return redirect(url_for("home"))

    posts = fetch_posts(subreddit, sort, limit)
    if posts is None:
        return redirect(url_for("home"))

    # Armazenar no session para uso posterior
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
        flash("Pipeline de sentimento não está disponível.", "danger")
        return redirect(url_for("home"))

    analysed_posts = []
    # Certifica-se de que a pasta static exista
    os.makedirs("static", exist_ok=True)
    text_accum = []
    neg_probs, neu_probs, pos_probs = [], [], []

    # Analisar cada post
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
                # Acumular para gráficos
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

    # Inicializar variáveis de caminho de gráfico
    resumo_chart = None
    wc_chart = None

    # Gerar gráfico de densidade apenas se tivermos ao menos 2 valores no total
    try:
        total_values = neg_probs + neu_probs + pos_probs
        if len(total_values) < 2:
            logger.info("Dados insuficientes para KDE (menos de 2 elementos no total). Pulando geração de densidade.")
        else:
            x = np.linspace(0, 100, 500)
            plt.figure(figsize=(8, 4))
            plotted = False

            # Para cada série, plotar apenas se houver mais de 1 valor e não todos zeros
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
            else:
                logger.info("Nenhuma série de probabilidades adequada para plotar KDE. Pulando.")
            plt.close()
    except Exception as e:
        logger.error("Erro ao gerar gráfico de densidade: %s", e, exc_info=True)

    # Gerar nuvem de palavras apenas se houver pelo menos 1 palavra após filtro de stopwords
    try:
        full_text = " ".join(text_accum).strip()
        words = re.findall(r"\w+", full_text)
        filtered_words = [w for w in words if w.lower() not in STOPWORDS]
        if not filtered_words:
            logger.info("Dados insuficientes para WordCloud (nenhuma palavra após filtro). Pulando geração de nuvem.")
        else:
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

    # Renderizar template passando os paths (ou None)
    return render_template(
        "detail_all.html",
        posts=analysed_posts,
        resumo_chart=resumo_chart,
        wc_chart=wc_chart
    )

@app.route("/gerar_relatorio", methods=["POST"])
def gerar_relatorio():
    posts = session.get("posts")
    if not posts:
        flash("Não há dados disponíveis para gerar relatório.", "warning")
        return redirect(url_for("home"))

    if not CONTAINER_ENDPOINT_SAS:
        logger.error("CONTAINER_ENDPOINT_SAS inválido ou ausente no gerar_relatorio.")
        flash("CONTAINER_ENDPOINT_SAS inválido ou ausente.", "danger")
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
    app.run(host="0.0.0.0", port=5000)
