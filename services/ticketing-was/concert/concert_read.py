from typing import Optional

from fastapi import APIRouter, Query
from fastapi.responses import JSONResponse

from concert.concert_read_cache import (
    get_concert_bootstrap_cached_or_load,
    get_concert_bootstrap_for_show,
    get_concert_detail_cached_or_load,
    get_concerts_list_cached_or_load,
)

router = APIRouter()


@router.get("/api/read/concerts")
def list_concerts():
    return get_concerts_list_cached_or_load()


@router.get("/api/read/concert/{concert_id}")
def get_concert_detail(concert_id: int):
    payload = get_concert_detail_cached_or_load(concert_id)
    if not payload:
        return JSONResponse(status_code=404, content={"message": "not found"})
    return payload


@router.get("/api/read/concert/{concert_id}/booking-bootstrap")
def get_concert_booking_bootstrap(concert_id: int, show_id: Optional[int] = Query(default=None)):
    if show_id is not None and show_id > 0:
        payload = get_concert_bootstrap_for_show(concert_id, show_id)
    else:
        payload = get_concert_bootstrap_cached_or_load(concert_id)
    if not payload:
        return JSONResponse(status_code=404, content={"message": "not found"})
    return payload
