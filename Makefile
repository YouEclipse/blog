build:
	docker build --rm -t blog .
run:
	cd /tmp/blog  && hugo server