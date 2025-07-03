use actix_web::{web, App, HttpServer, HttpResponse, Responder, get, middleware::Logger};
use serde::{Deserialize, Serialize};
use std::error::Error;
use std::fmt;

#[derive(Debug, Deserialize, Serialize)]
struct Pool {
    chain: String,
    project: String,
    symbol: String,
    #[serde(rename = "tvlUsd")]
    tvl_usd: f64,
    #[serde(rename = "apyBase")]
    apy_base: Option<f64>,
    #[serde(rename = "apyReward")]
    apy_reward: Option<f64>,
    apy: Option<f64>,
    #[serde(rename = "rewardTokens")]
    reward_tokens: Option<Vec<String>>,
    pool: String,
    #[serde(rename = "apyPct1D")]
    apy_pct_1d: Option<f64>,
    #[serde(rename = "apyPct7D")]
    apy_pct_7d: Option<f64>,
    #[serde(rename = "apyPct30D")]
    apy_pct_30d: Option<f64>,
    stablecoin: Option<bool>,
    #[serde(rename = "ilRisk")]
    il_risk: Option<String>,
    exposure: Option<String>,
    predictions: Option<serde_json::Value>,
    #[serde(rename = "poolMeta")]
    pool_meta: Option<serde_json::Value>,
    mu: Option<f64>,
    sigma: Option<f64>,
    count: Option<u32>,
    outlier: Option<bool>,
    #[serde(rename = "underlyingTokens")]
    underlying_tokens: Option<Vec<String>>,
    il7d: Option<f64>,
    #[serde(rename = "apyBase7d")]
    apy_base_7d: Option<f64>,
    #[serde(rename = "apyMean30d")]
    apy_mean_30d: Option<f64>,
    #[serde(rename = "volumeUsd1d")]
    volume_usd_1d: Option<f64>,
    #[serde(rename = "volumeUsd7d")]
    volume_usd_7d: Option<f64>,
    #[serde(rename = "apyBaseInception")]
    apy_base_inception: Option<f64>,
}

#[derive(Debug, Serialize)]
struct ApiResponse {
    success: bool,
    data: Option<Vec<Pool>>,
    message: Option<String>,
}

#[derive(Debug)]
struct ApiError {
    message: String,
}

impl fmt::Display for ApiError {
    fn fmt(&self, f: &mut fmt::Formatter) -> fmt::Result {
        write!(f, "{}", self.message)
    }
}

impl Error for ApiError {}

impl From<reqwest::Error> for ApiError {
    fn from(error: reqwest::Error) -> Self {
        ApiError {
            message: format!("HTTP request failed: {}", error),
        }
    }
}

impl From<serde_json::Error> for ApiError {
    fn from(error: serde_json::Error) -> Self {
        ApiError {
            message: format!("JSON parsing failed: {}", error),
        }
    }
}

fn is_main_pool(pool: &Pool) -> bool {
    // Check if pool_meta is null or empty
    match &pool.pool_meta {
        None => true,
        Some(value) => value.is_null(),
    }
}

#[get("/pools/{chain}/{project}/{symbol}")]
async fn get_filtered_pools(path: web::Path<(String, String, String)>) -> impl Responder {
    let (chain, project, symbol) = path.into_inner();
    
    match fetch_and_filter_pools(&chain, &project, &symbol).await {
        Ok(pools) => {
            if pools.is_empty() {
                HttpResponse::NotFound().json(ApiResponse {
                    success: false,
                    data: None,
                    message: Some(format!("No main pools found for chain: {}, project: {}, symbol: {}", chain, project, symbol)),
                })
            } else {
                HttpResponse::Ok().json(ApiResponse {
                    success: true,
                    data: Some(pools),
                    message: None,
                })
            }
        }
        Err(e) => {
            HttpResponse::InternalServerError().json(ApiResponse {
                success: false,
                data: None,
                message: Some(e.to_string()),
            })
        }
    }
}


#[get("/pools")]
async fn get_all_pools() -> impl Responder {
    match fetch_all_pools().await {
        Ok(pools) => {
            HttpResponse::Ok().json(ApiResponse {
                success: true,
                data: Some(pools),
                message: None,
            })
        }
        Err(e) => {
            HttpResponse::InternalServerError().json(ApiResponse {
                success: false,
                data: None,
                message: Some(e.to_string()),
            })
        }
    }
}

async fn fetch_and_filter_pools(chain: &str, project: &str, symbol: &str) -> Result<Vec<Pool>, ApiError> {
    let pools = fetch_all_pools().await?;
    
    let filtered_pools: Vec<Pool> = pools
        .into_iter()
        .filter(|pool| {
            pool.chain.to_lowercase() == chain.to_lowercase() &&
            pool.project.to_lowercase() == project.to_lowercase() &&
            pool.symbol.to_lowercase() == symbol.to_lowercase() &&
            is_main_pool(pool)  // Only return main pools (no poolMeta)
        })
        .collect();
    
    Ok(filtered_pools)
}

async fn fetch_all_pools() -> Result<Vec<Pool>, ApiError> {
    let url = "https://yields.llama.fi/pools";
    let client = reqwest::Client::new();
    
    let response = client
        .get(url)
        .header("User-Agent", "DeFi-Yields-API/1.0")
        .send()
        .await?;
    
    if !response.status().is_success() {
        return Err(ApiError {
            message: format!("API request failed with status: {}", response.status()),
        });
    }
    
    let data: serde_json::Value = response.json().await?;
    
    // The API returns an object with a "data" field containing the array of pools
    let pools_data = data["data"].as_array()
        .ok_or_else(|| ApiError {
            message: "Expected 'data' field with array of pools".to_string(),
        })?;
    
    let pools: Vec<Pool> = pools_data
        .iter()
        .filter_map(|pool| serde_json::from_value(pool.clone()).ok())
        .collect();
    
    Ok(pools)
}

#[actix_web::main]
async fn main() -> std::io::Result<()> {
    env_logger::init();
    
    // Get port from environment variable or default to 8080
    let port = std::env::var("PORT")
        .unwrap_or_else(|_| "8080".to_string())
        .parse::<u16>()
        .unwrap_or(8080);
    
    let bind_address = format!("0.0.0.0:{}", port);
    
    println!("Starting DeFi Yields API server on {}", bind_address);
    
    HttpServer::new(|| {
        App::new()
            .wrap(Logger::default())
            .service(get_all_pools)
            .service(get_filtered_pools)
    })
    .bind(&bind_address)?
    .run()
    .await
}