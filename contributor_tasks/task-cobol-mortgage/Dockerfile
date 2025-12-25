FROM ghcr.io/laude-institute/t-bench/python-3-13:20250620

WORKDIR /app

COPY src/ /app/src/

COPY data/ /app/data/

RUN pip install pytest==8.4.2

RUN apt-get update && apt-get install -y gnucobol3 && rm -rf /var/lib/apt/lists/*