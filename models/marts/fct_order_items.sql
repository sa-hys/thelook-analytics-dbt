{{ config(
    materialized='table',
    partition_by={
      "field": "order_month_jst",
      "data_type": "date",
      "granularity": "month"
    },
    cluster_by=['orders_created_at_jst','order_items_status'],
    persist_docs={"relation": true, "columns": true}
) }}

select
    oi.order_item_id,
    oi.order_id,
    o.created_at as orders_created_at,
    DATETIME(o.created_at, 'Asia/Tokyo') as orders_created_at_jst,
    DATE_TRUNC(DATE(o.created_at, 'Asia/Tokyo'), MONTH) AS order_month_jst,
    oi.user_id,
    u.country,
    oi.product_id,
    p.product_name,
    oi.status as order_items_status,
    case
        when shipped_at is not null and returned_at is null then 1
        else 0
    end as shipped,
    oi.sale_price
from {{ ref('stg_thelook__order_items')}} as oi
left join {{ ref('stg_thelook__orders')}} as o
    on oi.order_id = o.order_id
left join {{ ref('stg_thelook__products')}} as p
    on oi.product_id = p.product_id
left join {{ ref('stg_thelook__users')}} as u
    on oi.user_id = u.user_id
