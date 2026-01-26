# Ici, on a mis "TAG" à "MANUAL_BUILD_${date}" pour indiquer qu'il s'agit d'une construction manuelle.
# on a aussi mis "GIT_COMMIT" à "main" pour indiquer qu'on n'utilise pas un commit spécifique, mais il faudra peut être changer ça
docker build -t devsecops --build-arg BUILD_DATE="$(date)" --build-arg TAG="MANUAL_BUILD_$(date)" --build-arg GIT_COMMIT=main --build-arg GIT_URL="https://github.com/CamilleAntonios/tp03-devsecops" -f docker/Dockerfile .
docker run -d -p 8090:80 devsecops:latest