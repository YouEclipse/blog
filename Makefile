build:
	docker build --rm -t blog .
run:
	cd /tmp/blog  && hugo server -e production --bind 0.0.0.0 --port 80 --liveReloadPort 443