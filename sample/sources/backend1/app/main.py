from fastapi import FastAPI
from fastapi.middleware.cors import CORSMiddleware

# 목업: 회사·부서 5건 (하드코딩 JSON)
DEPARTMENTS = [
    {
        "id": 1,
        "company": "테크노 주식회사",
        "department": "개발본부",
        "location": "서울 강남",
    },
    {
        "id": 2,
        "company": "테크노 주식회사",
        "department": "운영본부",
        "location": "서울 판교",
    },
    {
        "id": 3,
        "company": "블루씨앤에스",
        "department": "영업팀",
        "location": "부산 해운대",
    },
    {
        "id": 4,
        "company": "블루씨앤에스",
        "department": "인사팀",
        "location": "부산 전포",
    },
    {
        "id": 5,
        "company": "그린이노베이션",
        "department": "연구소",
        "location": "대전 유성",
    },
]

app = FastAPI(title="Sample Backend1", version="1.0.0")

app.add_middleware(
    CORSMiddleware,
    allow_origins=["*"],
    allow_credentials=True,
    allow_methods=["*"],
    allow_headers=["*"],
)


@app.get("/health")
def health():
    return {"status": "ok"}


@app.get("/api/departments")
def list_departments():
    return {"items": DEPARTMENTS, "count": len(DEPARTMENTS)}
