select
    id as order_item_id,
    order_id,
    user_id,
    product_id,
    inventory_item_id,
    created_at,
    status,
    shipped_at,
    returned_at,
    sale_price
from {{ source('thelook','order_items')}}