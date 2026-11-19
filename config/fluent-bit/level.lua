-- Converte o nível textual do log do RabbitMQ para o nível numérico syslog exigido pelo GELF
-- (0 emergency, 1 alert, 2 critical, 3 error, 4 warning, 5 notice, 6 info, 7 debug).
-- Sem isso, "error" chegaria como texto e quebraria alertas do tipo "level <= 3" no Graylog.
local syslog_levels = {
    emergency = 0, alert = 1, critical = 2, error = 3,
    warning = 4, notice = 5, info = 6, debug = 7,
}

-- Nível desconhecido ou ausente vira info (6): nunca descartamos o registro nem o enviamos como texto.
local DEFAULT_LEVEL = 6

function to_syslog_level(tag, timestamp, record)
    local level = record["level"]
    if type(level) == "string" then
        record["level"] = syslog_levels[level] or DEFAULT_LEVEL
    elseif type(level) ~= "number" then
        record["level"] = DEFAULT_LEVEL
    end
    -- 2 = registro alterado, preservando o horário original do evento.
    return 2, timestamp, record
end
