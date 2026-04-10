from fastapi import FastAPI
from fastapi.middleware.cors import CORSMiddleware

from cors_ensure_middleware import EnsureCrossOriginCredentialsMiddleware
from auth.auth_user_read import router as auth_user_read_router
from concert.concert_read import router as concert_read_router
from movie.movie_cache_builder import rebuild_movie_cache
from movie.movie_read import router as movie_read_router
from theater.theaters_cache_builder import rebuild_theaters_cache
from theater.theaters_read import router as theaters_read_router
from user.user_read import router as user_read_router

READ_ROUTERS = [
    user_read_router,
    movie_read_router,
    theaters_read_router,
    concert_read_router,
    auth_user_read_router,
]

READ_CACHE_TARGETS = [
    {
        "name": "movie_read",
        "router": movie_read_router,
        "refresher": rebuild_movie_cache,
    },
    {
        "name": "theaters_read",
        "router": theaters_read_router,
        "refresher": rebuild_theaters_cache,
    },
]

app = FastAPI(title="Ticketing Read API")

# S3 웹사이트 등 다른 오리진에서 credentials 포함 요청 시 allow_origins=["*"] 는 브라우저 규격상 불가.
app.add_middleware(
    CORSMiddleware,
    allow_origin_regex=r"https?://.*",
    allow_credentials=True,
    allow_methods=["*"],
    allow_headers=["*"],
)
# CORSMiddleware가 붙이지 못하는 오류 응답에도 ACAO 보장 (브라우저 CORS 메시지 왜곡 방지)
app.add_middleware(EnsureCrossOriginCredentialsMiddleware)

for router in READ_ROUTERS:
    app.include_router(router)

@app.get("/")
def root_health():
    return {"message": "ok"}


@app.get("/api/read/health")
def health():
    return {"message": "read api ok"}
