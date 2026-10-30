select 
    id as user_id,
    concat(first_name,' ',last_name) as user_name,
    gender,
    country,
    created_at


 from {{ source('thelook','users')}}
