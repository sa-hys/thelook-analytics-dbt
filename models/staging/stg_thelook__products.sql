select 
    id as product_id,
    category,
    brand,
    name as product_name,
    cost
from {{ source('thelook','products') }}