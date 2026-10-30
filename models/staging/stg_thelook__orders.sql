select 
    order_id,
    user_id,
    status,
    created_at,
    num_of_item as item_count
from {{ source('thelook','orders')}}