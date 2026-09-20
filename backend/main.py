import hmac
import os
from pathlib import Path

from Crypto.Hash import CMAC
from Crypto.Cipher import AES
from dotenv import load_dotenv
from fastapi import FastAPI, HTTPException
from fastapi.staticfiles import StaticFiles
from pydantic import BaseModel, Field
from web3 import Web3


load_dotenv(Path(__file__).resolve().parents[1] / ".env")

RPC_URL = os.environ["RPC_URL"]
PRIVATE_KEY = os.environ["PRIVATE_KEY"]
CONTRACT_ADDRESS = os.environ["CONTRACT_ADDRESS"]

w3 = Web3(Web3.HTTPProvider(RPC_URL, request_kwargs={"timeout": 15}))
if not w3.is_connected():
    raise RuntimeError(f"No se pudo conectar al RPC: {RPC_URL}")

try:
    CONTRACT_ADDRESS = Web3.to_checksum_address(CONTRACT_ADDRESS)
except ValueError as error:
    raise RuntimeError("CONTRACT_ADDRESS no es una dirección válida") from error

account = w3.eth.account.from_key(PRIVATE_KEY)

CONTRACT_ABI = [
    {
        "inputs": [{"internalType": "uint256", "name": "", "type": "uint256"}],
        "name": "consumed",
        "outputs": [{"internalType": "bool", "name": "", "type": "bool"}],
        "stateMutability": "view",
        "type": "function",
    },
    {
        "inputs": [{"internalType": "uint256", "name": "tokenId", "type": "uint256"}],
        "name": "consumeTicket",
        "outputs": [],
        "stateMutability": "nonpayable",
        "type": "function",
    },
    {
        "inputs": [{"internalType": "address", "name": "to", "type": "address"}],
        "name": "mintTicket",
        "outputs": [{"internalType": "uint256", "name": "tokenId", "type": "uint256"}],
        "stateMutability": "nonpayable",
        "type": "function",
    },
    {
        "inputs": [],
        "name": "withdraw",
        "outputs": [],
        "stateMutability": "nonpayable",
        "type": "function",
    },
]

contract = w3.eth.contract(address=CONTRACT_ADDRESS, abi=CONTRACT_ABI)
app = FastAPI(title="ETHCali NFC Ticket Validator")
from fastapi.middleware.cors import CORSMiddleware

app = FastAPI(title="ETHCali NFC Ticket Validator")

# AGREGA ESTO AQUÍ:
app.add_middleware(
    CORSMiddleware,
    allow_origins=["*"],  # Permite peticiones desde cualquier frontend (Vercel)
    allow_credentials=True,
    allow_methods=["*"],  # Permite POST, GET, etc.
    allow_headers=["*"],
)

# Demo-only AES-CMAC key. Replace with the NTAG key-management flow before production.
DUMMY_NFC_KEY = b"ETHCaliDemoKey16"


class NFCScan(BaseModel):
    token_id: int = Field(gt=0)
    # Demo payload format: nonce:cmac_hex, where CMAC covers "token_id:nonce".
    nfc_payload: str | None = Field(default=None, max_length=200)


class MintRequest(BaseModel):
    attendee_address: str = Field(min_length=42, max_length=42)


def dummy_nfc_payload(token_id: int) -> str:
    nonce = "demo"
    message = f"{token_id}:{nonce}".encode()
    mac = CMAC.new(DUMMY_NFC_KEY, ciphermod=AES)
    mac.update(message)
    return f"{nonce}:{mac.hexdigest()}"


def verify_dummy_nfc(token_id: int, nfc_payload: str) -> bool:
    try:
        nonce, provided_mac = nfc_payload.split(":", 1)
        if not nonce or len(provided_mac) != 32:
            return False
        bytes.fromhex(provided_mac)
    except ValueError:
        return False

    message = f"{token_id}:{nonce}".encode()
    mac = CMAC.new(DUMMY_NFC_KEY, ciphermod=AES)
    mac.update(message)
    expected_mac = mac.hexdigest()
    return hmac.compare_digest(expected_mac, provided_mac.lower())


@app.get("/health")
def health() -> dict[str, object]:
    return {"ok": True, "chain_id": w3.eth.chain_id, "contract": CONTRACT_ADDRESS}


@app.post("/mint")
def mint_ticket(request: MintRequest) -> dict[str, str]:
    try:
        attendee_address = Web3.to_checksum_address(request.attendee_address)
    except ValueError as error:
        raise HTTPException(status_code=400, detail="Wallet inválida") from error

    try:
        nonce = w3.eth.get_transaction_count(account.address, "pending")
        transaction = contract.functions.mintTicket(attendee_address).build_transaction(
            {
                "from": account.address,
                "nonce": nonce,
                "chainId": w3.eth.chain_id,
                "gas": 150_000,
                "maxFeePerGas": w3.to_wei(2, "gwei"),
                "maxPriorityFeePerGas": w3.to_wei(1, "wei"),
            }
        )
        signed_transaction = account.sign_transaction(transaction)
        tx_hash = w3.eth.send_raw_transaction(signed_transaction.raw_transaction)
    except Exception as error:
        raise HTTPException(status_code=502, detail="No se pudo enviar mintTicket") from error

    return {"message": "Ticket emitido", "transaction_hash": tx_hash.hex()}


@app.post("/withdraw")
def withdraw() -> dict[str, str]:
    balance = w3.eth.get_balance(CONTRACT_ADDRESS)
    if balance == 0:
        raise HTTPException(status_code=400, detail="No hay regalías disponibles para retirar")

    try:
        nonce = w3.eth.get_transaction_count(account.address, "pending")
        transaction = contract.functions.withdraw().build_transaction(
            {
                "from": account.address,
                "nonce": nonce,
                "chainId": w3.eth.chain_id,
                "gas": 100_000,
                "maxFeePerGas": w3.to_wei(2, "gwei"),
                "maxPriorityFeePerGas": w3.to_wei(1, "wei"),
            }
        )
        signed_transaction = account.sign_transaction(transaction)
        tx_hash = w3.eth.send_raw_transaction(signed_transaction.raw_transaction)
    except Exception as error:
        raise HTTPException(status_code=502, detail="No se pudo retirar el saldo") from error

    return {
        "message": "Regalías retiradas",
        "amount_wei": str(balance),
        "transaction_hash": tx_hash.hex(),
    }


@app.post("/scan_nfc")
def scan_nfc(scan: NFCScan) -> dict[str, str | int]:
    nfc_payload = dummy_nfc_payload(scan.token_id) if scan.nfc_payload == "demo" else scan.nfc_payload
    if not nfc_payload or not verify_dummy_nfc(scan.token_id, nfc_payload):
        raise HTTPException(status_code=400, detail="Payload NFC inválido")

    try:
        already_consumed = contract.functions.consumed(scan.token_id).call()
    except Exception as error:
        raise HTTPException(status_code=502, detail="No se pudo consultar el contrato") from error

    if already_consumed:
        raise HTTPException(status_code=409, detail="Ticket ya utilizado: acceso denegado")

    try:
        nonce = w3.eth.get_transaction_count(account.address, "pending")
        transaction = contract.functions.consumeTicket(scan.token_id).build_transaction(
            {
                "from": account.address,
                "nonce": nonce,
                "chainId": w3.eth.chain_id,
                "gas": 150_000,
                "maxFeePerGas": w3.to_wei(2, "gwei"),
                "maxPriorityFeePerGas": w3.to_wei(1, "wei"),
            }
        )
        signed_transaction = account.sign_transaction(transaction)
        tx_hash = w3.eth.send_raw_transaction(signed_transaction.raw_transaction)
    except Exception as error:
        raise HTTPException(status_code=502, detail="No se pudo enviar consumeTicket") from error

    return {
        "message": "Acceso Concedido",
        "token_id": scan.token_id,
        "transaction_hash": tx_hash.hex(),
    }


app.mount("/", StaticFiles(directory=Path(__file__).resolve().parents[1] / "frontend", html=True), name="frontend")
