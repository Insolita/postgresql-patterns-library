-- inspired by https://postgres.ai/blog/20210923-zero-downtime-postgres-schema-migrations-lock-timeout-and-retries

create or replace procedure execute_attempt(
    --обязательные параметры:
    query text,
    --необязательные параметры:
    lock_timeout text default '100ms',
    max_attempts int default 50
)
    language plpgsql
as
$procedure$
declare
    lock_timeout_old constant text not null default current_setting('lock_timeout');
    time_start constant timestamp not null default clock_timestamp();
    time_elapsed numeric not null default 0; -- длительность выполнения всех запросов, в секундах
    delay numeric not null default 0;
begin
    perform set_config('lock_timeout', lock_timeout, true);

    for cur_attempt in 1..max_attempts loop
        begin
            execute query;
            perform set_config('lock_timeout', lock_timeout_old, true);
            exit;
        exception when lock_not_available then
            if cur_attempt < max_attempts then
                time_elapsed := round(extract('epoch' from clock_timestamp() - time_start)::numeric, 2);
                delay := round(greatest(sqrt(time_elapsed * 1), 1), 2);
                raise warning
                    'Attempt % of % to execute query failed due lock timeout %, next replay after % second',
                    cur_attempt, max_attempts, lock_timeout, delay;
                perform pg_sleep(delay);
            else
                perform set_config('lock_timeout', lock_timeout_old, true);
                raise warning
                    'Attempt % of % to execute query failed due lock timeout %',
                    cur_attempt, max_attempts, lock_timeout;
                raise; -- raise the original exception
            end if;
        end;
    end loop;

end
$procedure$;

comment on procedure execute_attempt(
    --обязательные параметры:
    query text,
    --необязательные параметры:
    lock_timeout text,
    max_attempts int
) is $$
    Процедура предназначена для безопасного выполнения DDL запросов в БД. Например, миграций БД.
    Пытается выполнить запрос с учётом ограничения lock_timeout.
    В случае неудачи делает задержку выполнения и повторяет попытку N раз.
$$;
