from fastapi import FastAPI
from fastapi.middleware.cors import CORSMiddleware

# 목업: 직원 30명 (하드코딩 JSON)
EMPLOYEES = [
    {"id": 1, "name": "김민준", "company": "테크노 주식회사", "department": "개발본부", "role": "백엔드"},
    {"id": 2, "name": "이서연", "company": "테크노 주식회사", "department": "개발본부", "role": "프론트엔드"},
    {"id": 3, "name": "박도윤", "company": "테크노 주식회사", "department": "운영본부", "role": "SRE"},
    {"id": 4, "name": "최하은", "company": "테크노 주식회사", "department": "운영본부", "role": "데브옵스"},
    {"id": 5, "name": "정지호", "company": "블루씨앤에스", "department": "영업팀", "role": "영업"},
    {"id": 6, "name": "강유진", "company": "블루씨앤에스", "department": "영업팀", "role": "영업"},
    {"id": 7, "name": "윤시우", "company": "블루씨앤에스", "department": "인사팀", "role": "채용"},
    {"id": 8, "name": "장수아", "company": "블루씨앤에스", "department": "인사팀", "role": "교육"},
    {"id": 9, "name": "임재현", "company": "그린이노베이션", "department": "연구소", "role": "연구원"},
    {"id": 10, "name": "한예린", "company": "그린이노베이션", "department": "연구소", "role": "연구원"},
    {"id": 11, "name": "오준서", "company": "테크노 주식회사", "department": "개발본부", "role": "풀스택"},
    {"id": 12, "name": "신다은", "company": "테크노 주식회사", "department": "개발본부", "role": "QA"},
    {"id": 13, "name": "권태양", "company": "테크노 주식회사", "department": "운영본부", "role": "모니터링"},
    {"id": 14, "name": "배소율", "company": "블루씨앤에스", "department": "영업팀", "role": "마케팅"},
    {"id": 15, "name": "홍우진", "company": "블루씨앤에스", "department": "인사팀", "role": "급여"},
    {"id": 16, "name": "남기범", "company": "그린이노베이션", "department": "연구소", "role": "선임연구원"},
    {"id": 17, "name": "서지안", "company": "그린이노베이션", "department": "연구소", "role": "연구원"},
    {"id": 18, "name": "안태희", "company": "테크노 주식회사", "department": "개발본부", "role": "데이터"},
    {"id": 19, "name": "유채원", "company": "테크노 주식회사", "department": "운영본부", "role": "보안"},
    {"id": 20, "name": "노승민", "company": "블루씨앤에스", "department": "영업팀", "role": "CS"},
    {"id": 21, "name": "문하린", "company": "블루씨앤에스", "department": "인사팀", "role": "복리후생"},
    {"id": 22, "name": "양지훈", "company": "그린이노베이션", "department": "연구소", "role": "실험담당"},
    {"id": 23, "name": "구민재", "company": "테크노 주식회사", "department": "개발본부", "role": "모바일"},
    {"id": 24, "name": "손예나", "company": "테크노 주식회사", "department": "운영본부", "role": "인프라"},
    {"id": 25, "name": "백도현", "company": "블루씨앤에스", "department": "영업팀", "role": "해외영업"},
    {"id": 26, "name": "엄서윤", "company": "블루씨앤에스", "department": "인사팀", "role": "평가"},
    {"id": 27, "name": "표민성", "company": "그린이노베이션", "department": "연구소", "role": "특허"},
    {"id": 28, "name": "피주원", "company": "테크노 주식회사", "department": "개발본부", "role": "아키텍트"},
    {"id": 29, "name": "탁은지", "company": "블루씨앤에스", "department": "영업팀", "role": "기획"},
    {"id": 30, "name": "해민규", "company": "그린이노베이션", "department": "연구소", "role": "PM"},
]

app = FastAPI(title="Sample Backend2", version="1.0.0")

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


@app.get("/api/employees")
def list_employees():
    return {"items": EMPLOYEES, "count": len(EMPLOYEES)}
