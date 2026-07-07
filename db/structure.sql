SET statement_timeout = 0;
SET lock_timeout = 0;
SET idle_in_transaction_session_timeout = 0;
SET client_encoding = 'UTF8';
SET standard_conforming_strings = on;
SELECT pg_catalog.set_config('search_path', '', false);
SET check_function_bodies = false;
SET xmloption = content;
SET client_min_messages = warning;
SET row_security = off;

--
-- Name: pg_stat_statements; Type: EXTENSION; Schema: -; Owner: -
--

CREATE EXTENSION IF NOT EXISTS pg_stat_statements WITH SCHEMA public;


--
-- Name: EXTENSION pg_stat_statements; Type: COMMENT; Schema: -; Owner: -
--

COMMENT ON EXTENSION pg_stat_statements IS 'track planning and execution statistics of all SQL statements executed';


--
-- Name: pgcrypto; Type: EXTENSION; Schema: -; Owner: -
--

CREATE EXTENSION IF NOT EXISTS pgcrypto WITH SCHEMA public;


--
-- Name: EXTENSION pgcrypto; Type: COMMENT; Schema: -; Owner: -
--

COMMENT ON EXTENSION pgcrypto IS 'cryptographic functions';


--
-- Name: comeals_protect_settled_meal(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.comeals_protect_settled_meal() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
BEGIN
  IF current_setting('comeals.allow_settled_writes', true) = 'on' THEN
    RETURN CASE TG_OP WHEN 'DELETE' THEN OLD ELSE NEW END;
  END IF;

  IF TG_OP = 'DELETE' THEN
    IF OLD.reconciliation_id IS NOT NULL THEN
      RAISE EXCEPTION 'DELETE on meals refused: meal % is reconciled and settled source data '
        'cannot be erased. For genuine data corruption see docs/runbooks/settled-data-repair.md.',
        OLD.id;
    END IF;
    RETURN OLD;
  END IF;

  IF OLD.reconciliation_id IS NULL THEN
    RETURN NEW;
  END IF;

  IF NEW.reconciliation_id IS DISTINCT FROM OLD.reconciliation_id
     OR NEW.cap IS DISTINCT FROM OLD.cap
     OR NEW.date IS DISTINCT FROM OLD.date THEN
    RAISE EXCEPTION 'UPDATE on meals refused: meal % is reconciled; cap, date, and '
      'reconciliation_id are frozen. For genuine data corruption see '
      'docs/runbooks/settled-data-repair.md.',
      OLD.id;
  END IF;

  RETURN NEW;
END;
$$;


--
-- Name: comeals_reject_settled_child_write(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.comeals_reject_settled_child_write() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
DECLARE
  settled_meal_id bigint;
BEGIN
  IF current_setting('comeals.allow_settled_writes', true) = 'on' THEN
    RETURN CASE TG_OP WHEN 'DELETE' THEN OLD ELSE NEW END;
  END IF;

  IF TG_OP IN ('UPDATE', 'DELETE') THEN
    SELECT id INTO settled_meal_id FROM meals
    WHERE id = OLD.meal_id AND reconciliation_id IS NOT NULL;
  END IF;

  IF settled_meal_id IS NULL AND TG_OP IN ('INSERT', 'UPDATE') THEN
    SELECT id INTO settled_meal_id FROM meals
    WHERE id = NEW.meal_id AND reconciliation_id IS NOT NULL;
  END IF;

  IF settled_meal_id IS NOT NULL THEN
    RAISE EXCEPTION '% on % refused: meal % is reconciled and its ledger rows are immutable. '
      'Corrections belong in the next reconciliation. For genuine data corruption see '
      'docs/runbooks/settled-data-repair.md.',
      TG_OP, TG_TABLE_NAME, settled_meal_id;
  END IF;

  RETURN CASE TG_OP WHEN 'DELETE' THEN OLD ELSE NEW END;
END;
$$;


--
-- Name: prevent_community_delete(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.prevent_community_delete() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
BEGIN
  RAISE EXCEPTION 'Cannot delete the singleton community record';
END;
$$;


SET default_tablespace = '';

SET default_table_access_method = heap;

--
-- Name: admin_users; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.admin_users (
    id bigint NOT NULL,
    community_id bigint,
    created_at timestamp without time zone NOT NULL,
    current_sign_in_at timestamp without time zone,
    current_sign_in_ip inet,
    email character varying DEFAULT ''::character varying NOT NULL,
    encrypted_password character varying DEFAULT ''::character varying NOT NULL,
    last_sign_in_at timestamp without time zone,
    last_sign_in_ip inet,
    remember_created_at timestamp without time zone,
    reset_password_sent_at timestamp without time zone,
    reset_password_token character varying,
    sign_in_count integer DEFAULT 0 NOT NULL,
    superuser boolean DEFAULT false NOT NULL,
    updated_at timestamp without time zone NOT NULL
);


--
-- Name: admin_users_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.admin_users_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: admin_users_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.admin_users_id_seq OWNED BY public.admin_users.id;


--
-- Name: ar_internal_metadata; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.ar_internal_metadata (
    key character varying NOT NULL,
    value character varying,
    created_at timestamp(6) without time zone NOT NULL,
    updated_at timestamp(6) without time zone NOT NULL
);


--
-- Name: audits; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.audits (
    id bigint NOT NULL,
    action character varying,
    associated_id integer,
    associated_type character varying,
    auditable_id integer,
    auditable_type character varying,
    audited_changes jsonb,
    comment character varying,
    created_at timestamp without time zone,
    remote_address character varying,
    request_uuid character varying,
    user_id integer,
    user_type character varying,
    username character varying,
    version integer DEFAULT 0
);


--
-- Name: audits_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.audits_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: audits_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.audits_id_seq OWNED BY public.audits.id;


--
-- Name: bills; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.bills (
    id bigint NOT NULL,
    amount numeric(12,8) DEFAULT 0.0 NOT NULL,
    community_id bigint NOT NULL,
    created_at timestamp without time zone NOT NULL,
    meal_id bigint NOT NULL,
    no_cost boolean DEFAULT false NOT NULL,
    resident_id bigint NOT NULL,
    updated_at timestamp without time zone NOT NULL,
    CONSTRAINT bills_amount_non_negative CHECK ((amount >= (0)::numeric))
);


--
-- Name: bills_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.bills_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: bills_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.bills_id_seq OWNED BY public.bills.id;


--
-- Name: common_house_reservations; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.common_house_reservations (
    id bigint NOT NULL,
    community_id bigint NOT NULL,
    created_at timestamp without time zone NOT NULL,
    end_date timestamp without time zone NOT NULL,
    resident_id bigint NOT NULL,
    start_date timestamp without time zone NOT NULL,
    title character varying,
    updated_at timestamp without time zone NOT NULL
);


--
-- Name: common_house_reservations_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.common_house_reservations_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: common_house_reservations_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.common_house_reservations_id_seq OWNED BY public.common_house_reservations.id;


--
-- Name: communities; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.communities (
    id bigint NOT NULL,
    cap numeric(12,8),
    created_at timestamp without time zone NOT NULL,
    name character varying NOT NULL,
    singleton_guard integer DEFAULT 0 NOT NULL,
    slug character varying NOT NULL,
    timezone character varying NOT NULL,
    updated_at timestamp without time zone NOT NULL,
    CONSTRAINT communities_cap_positive_or_null CHECK (((cap IS NULL) OR (cap > (0)::numeric)))
);


--
-- Name: communities_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.communities_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: communities_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.communities_id_seq OWNED BY public.communities.id;


--
-- Name: events; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.events (
    id bigint NOT NULL,
    allday boolean DEFAULT false NOT NULL,
    community_id bigint NOT NULL,
    created_at timestamp without time zone NOT NULL,
    description character varying DEFAULT ''::character varying NOT NULL,
    end_date timestamp without time zone,
    start_date timestamp without time zone NOT NULL,
    title character varying NOT NULL,
    updated_at timestamp without time zone NOT NULL
);


--
-- Name: events_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.events_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: events_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.events_id_seq OWNED BY public.events.id;


--
-- Name: friendly_id_slugs; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.friendly_id_slugs (
    id bigint NOT NULL,
    created_at timestamp without time zone,
    scope character varying,
    slug character varying NOT NULL,
    sluggable_id integer NOT NULL,
    sluggable_type character varying(50)
);


--
-- Name: friendly_id_slugs_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.friendly_id_slugs_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: friendly_id_slugs_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.friendly_id_slugs_id_seq OWNED BY public.friendly_id_slugs.id;


--
-- Name: guest_room_reservations; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.guest_room_reservations (
    id bigint NOT NULL,
    community_id bigint NOT NULL,
    created_at timestamp without time zone NOT NULL,
    date date NOT NULL,
    resident_id bigint NOT NULL,
    updated_at timestamp without time zone NOT NULL
);


--
-- Name: guest_room_reservations_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.guest_room_reservations_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: guest_room_reservations_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.guest_room_reservations_id_seq OWNED BY public.guest_room_reservations.id;


--
-- Name: guests; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.guests (
    id bigint NOT NULL,
    created_at timestamp without time zone NOT NULL,
    late boolean DEFAULT false NOT NULL,
    meal_id bigint NOT NULL,
    multiplier integer DEFAULT 2 NOT NULL,
    resident_id bigint NOT NULL,
    updated_at timestamp without time zone NOT NULL,
    vegetarian boolean DEFAULT false NOT NULL,
    CONSTRAINT guests_multiplier_non_negative CHECK ((multiplier >= 0))
);


--
-- Name: guests_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.guests_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: guests_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.guests_id_seq OWNED BY public.guests.id;


--
-- Name: keys; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.keys (
    id bigint NOT NULL,
    created_at timestamp without time zone NOT NULL,
    identity_id bigint NOT NULL,
    identity_type character varying NOT NULL,
    token character varying NOT NULL,
    updated_at timestamp without time zone NOT NULL
);


--
-- Name: keys_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.keys_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: keys_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.keys_id_seq OWNED BY public.keys.id;


--
-- Name: meal_residents; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.meal_residents (
    id bigint NOT NULL,
    community_id bigint NOT NULL,
    created_at timestamp without time zone NOT NULL,
    late boolean DEFAULT false NOT NULL,
    meal_id bigint NOT NULL,
    multiplier integer NOT NULL,
    resident_id bigint NOT NULL,
    updated_at timestamp without time zone NOT NULL,
    vegetarian boolean DEFAULT false NOT NULL,
    CONSTRAINT meal_residents_multiplier_non_negative CHECK ((multiplier >= 0))
);


--
-- Name: meal_residents_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.meal_residents_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: meal_residents_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.meal_residents_id_seq OWNED BY public.meal_residents.id;


--
-- Name: meals; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.meals (
    id bigint NOT NULL,
    cap numeric(12,8),
    closed boolean DEFAULT false NOT NULL,
    closed_at timestamp without time zone,
    community_id bigint NOT NULL,
    created_at timestamp without time zone NOT NULL,
    date date NOT NULL,
    description text DEFAULT ''::text NOT NULL,
    max integer,
    reconciliation_id bigint,
    rotation_id bigint,
    start_time timestamp without time zone NOT NULL,
    updated_at timestamp without time zone NOT NULL,
    CONSTRAINT meals_cap_positive_or_null CHECK (((cap IS NULL) OR (cap > (0)::numeric)))
);


--
-- Name: meals_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.meals_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: meals_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.meals_id_seq OWNED BY public.meals.id;


--
-- Name: reconciliation_balances; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.reconciliation_balances (
    id bigint NOT NULL,
    amount numeric(12,8) DEFAULT 0.0 NOT NULL,
    created_at timestamp(6) without time zone NOT NULL,
    reconciliation_id bigint NOT NULL,
    resident_id bigint NOT NULL,
    updated_at timestamp(6) without time zone NOT NULL
);


--
-- Name: reconciliation_balances_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.reconciliation_balances_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: reconciliation_balances_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.reconciliation_balances_id_seq OWNED BY public.reconciliation_balances.id;


--
-- Name: reconciliations; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.reconciliations (
    id bigint NOT NULL,
    community_id bigint NOT NULL,
    created_at timestamp without time zone NOT NULL,
    date date NOT NULL,
    end_date date NOT NULL,
    updated_at timestamp without time zone NOT NULL
);


--
-- Name: reconciliations_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.reconciliations_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: reconciliations_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.reconciliations_id_seq OWNED BY public.reconciliations.id;


--
-- Name: resident_balances; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.resident_balances (
    id bigint NOT NULL,
    amount numeric(12,8) DEFAULT 0.0 NOT NULL,
    created_at timestamp without time zone NOT NULL,
    resident_id bigint NOT NULL,
    updated_at timestamp without time zone NOT NULL,
    CONSTRAINT resident_balances_amount_not_nan CHECK ((amount = amount))
);


--
-- Name: resident_balances_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.resident_balances_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: resident_balances_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.resident_balances_id_seq OWNED BY public.resident_balances.id;


--
-- Name: residents; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.residents (
    id bigint NOT NULL,
    active boolean DEFAULT true NOT NULL,
    birthday date DEFAULT '1900-01-01'::date NOT NULL,
    can_cook boolean DEFAULT true NOT NULL,
    community_id bigint NOT NULL,
    created_at timestamp without time zone NOT NULL,
    email character varying,
    keys_valid_since timestamp(6) without time zone DEFAULT CURRENT_TIMESTAMP NOT NULL,
    multiplier integer DEFAULT 2 NOT NULL,
    name character varying NOT NULL,
    password_digest character varying NOT NULL,
    reset_password_sent_at timestamp(6) without time zone,
    reset_password_token character varying,
    unit_id bigint NOT NULL,
    updated_at timestamp without time zone NOT NULL,
    vegetarian boolean DEFAULT false NOT NULL,
    CONSTRAINT residents_multiplier_non_negative CHECK ((multiplier >= 0))
);


--
-- Name: residents_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.residents_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: residents_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.residents_id_seq OWNED BY public.residents.id;


--
-- Name: rotations; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.rotations (
    id bigint NOT NULL,
    color character varying NOT NULL,
    community_id bigint NOT NULL,
    created_at timestamp without time zone NOT NULL,
    description character varying DEFAULT ''::character varying NOT NULL,
    new_rotation_notified_at timestamp(6) without time zone,
    place_value integer,
    residents_notified boolean DEFAULT false NOT NULL,
    start_date date,
    updated_at timestamp without time zone NOT NULL
);


--
-- Name: rotations_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.rotations_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: rotations_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.rotations_id_seq OWNED BY public.rotations.id;


--
-- Name: schema_migrations; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.schema_migrations (
    version character varying NOT NULL
);


--
-- Name: units; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.units (
    id bigint NOT NULL,
    community_id bigint NOT NULL,
    created_at timestamp without time zone NOT NULL,
    name character varying NOT NULL,
    updated_at timestamp without time zone NOT NULL
);


--
-- Name: units_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.units_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: units_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.units_id_seq OWNED BY public.units.id;


--
-- Name: admin_users id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.admin_users ALTER COLUMN id SET DEFAULT nextval('public.admin_users_id_seq'::regclass);


--
-- Name: audits id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.audits ALTER COLUMN id SET DEFAULT nextval('public.audits_id_seq'::regclass);


--
-- Name: bills id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.bills ALTER COLUMN id SET DEFAULT nextval('public.bills_id_seq'::regclass);


--
-- Name: common_house_reservations id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.common_house_reservations ALTER COLUMN id SET DEFAULT nextval('public.common_house_reservations_id_seq'::regclass);


--
-- Name: communities id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.communities ALTER COLUMN id SET DEFAULT nextval('public.communities_id_seq'::regclass);


--
-- Name: events id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.events ALTER COLUMN id SET DEFAULT nextval('public.events_id_seq'::regclass);


--
-- Name: friendly_id_slugs id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.friendly_id_slugs ALTER COLUMN id SET DEFAULT nextval('public.friendly_id_slugs_id_seq'::regclass);


--
-- Name: guest_room_reservations id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.guest_room_reservations ALTER COLUMN id SET DEFAULT nextval('public.guest_room_reservations_id_seq'::regclass);


--
-- Name: guests id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.guests ALTER COLUMN id SET DEFAULT nextval('public.guests_id_seq'::regclass);


--
-- Name: keys id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.keys ALTER COLUMN id SET DEFAULT nextval('public.keys_id_seq'::regclass);


--
-- Name: meal_residents id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.meal_residents ALTER COLUMN id SET DEFAULT nextval('public.meal_residents_id_seq'::regclass);


--
-- Name: meals id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.meals ALTER COLUMN id SET DEFAULT nextval('public.meals_id_seq'::regclass);


--
-- Name: reconciliation_balances id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.reconciliation_balances ALTER COLUMN id SET DEFAULT nextval('public.reconciliation_balances_id_seq'::regclass);


--
-- Name: reconciliations id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.reconciliations ALTER COLUMN id SET DEFAULT nextval('public.reconciliations_id_seq'::regclass);


--
-- Name: resident_balances id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.resident_balances ALTER COLUMN id SET DEFAULT nextval('public.resident_balances_id_seq'::regclass);


--
-- Name: residents id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.residents ALTER COLUMN id SET DEFAULT nextval('public.residents_id_seq'::regclass);


--
-- Name: rotations id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.rotations ALTER COLUMN id SET DEFAULT nextval('public.rotations_id_seq'::regclass);


--
-- Name: units id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.units ALTER COLUMN id SET DEFAULT nextval('public.units_id_seq'::regclass);


--
-- Name: admin_users admin_users_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.admin_users
    ADD CONSTRAINT admin_users_pkey PRIMARY KEY (id);


--
-- Name: ar_internal_metadata ar_internal_metadata_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.ar_internal_metadata
    ADD CONSTRAINT ar_internal_metadata_pkey PRIMARY KEY (key);


--
-- Name: audits audits_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.audits
    ADD CONSTRAINT audits_pkey PRIMARY KEY (id);


--
-- Name: bills bills_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.bills
    ADD CONSTRAINT bills_pkey PRIMARY KEY (id);


--
-- Name: common_house_reservations common_house_reservations_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.common_house_reservations
    ADD CONSTRAINT common_house_reservations_pkey PRIMARY KEY (id);


--
-- Name: communities communities_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.communities
    ADD CONSTRAINT communities_pkey PRIMARY KEY (id);


--
-- Name: events events_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.events
    ADD CONSTRAINT events_pkey PRIMARY KEY (id);


--
-- Name: friendly_id_slugs friendly_id_slugs_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.friendly_id_slugs
    ADD CONSTRAINT friendly_id_slugs_pkey PRIMARY KEY (id);


--
-- Name: guest_room_reservations guest_room_reservations_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.guest_room_reservations
    ADD CONSTRAINT guest_room_reservations_pkey PRIMARY KEY (id);


--
-- Name: guests guests_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.guests
    ADD CONSTRAINT guests_pkey PRIMARY KEY (id);


--
-- Name: keys keys_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.keys
    ADD CONSTRAINT keys_pkey PRIMARY KEY (id);


--
-- Name: meal_residents meal_residents_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.meal_residents
    ADD CONSTRAINT meal_residents_pkey PRIMARY KEY (id);


--
-- Name: meals meals_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.meals
    ADD CONSTRAINT meals_pkey PRIMARY KEY (id);


--
-- Name: reconciliation_balances reconciliation_balances_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.reconciliation_balances
    ADD CONSTRAINT reconciliation_balances_pkey PRIMARY KEY (id);


--
-- Name: reconciliations reconciliations_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.reconciliations
    ADD CONSTRAINT reconciliations_pkey PRIMARY KEY (id);


--
-- Name: resident_balances resident_balances_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.resident_balances
    ADD CONSTRAINT resident_balances_pkey PRIMARY KEY (id);


--
-- Name: residents residents_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.residents
    ADD CONSTRAINT residents_pkey PRIMARY KEY (id);


--
-- Name: rotations rotations_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.rotations
    ADD CONSTRAINT rotations_pkey PRIMARY KEY (id);


--
-- Name: schema_migrations schema_migrations_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.schema_migrations
    ADD CONSTRAINT schema_migrations_pkey PRIMARY KEY (version);


--
-- Name: units units_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.units
    ADD CONSTRAINT units_pkey PRIMARY KEY (id);


--
-- Name: associated_index; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX associated_index ON public.audits USING btree (associated_type, associated_id);


--
-- Name: auditable_index; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX auditable_index ON public.audits USING btree (auditable_type, auditable_id);


--
-- Name: index_admin_users_on_email; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX index_admin_users_on_email ON public.admin_users USING btree (email);


--
-- Name: index_admin_users_on_reset_password_token; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX index_admin_users_on_reset_password_token ON public.admin_users USING btree (reset_password_token);


--
-- Name: index_bills_on_meal_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_bills_on_meal_id ON public.bills USING btree (meal_id);


--
-- Name: index_bills_on_meal_id_and_resident_id; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX index_bills_on_meal_id_and_resident_id ON public.bills USING btree (meal_id, resident_id);


--
-- Name: index_bills_on_resident_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_bills_on_resident_id ON public.bills USING btree (resident_id);


--
-- Name: index_common_house_reservations_on_resident_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_common_house_reservations_on_resident_id ON public.common_house_reservations USING btree (resident_id);


--
-- Name: index_common_house_reservations_on_start_date; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_common_house_reservations_on_start_date ON public.common_house_reservations USING btree (start_date);


--
-- Name: index_communities_on_name; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX index_communities_on_name ON public.communities USING btree (name);


--
-- Name: index_communities_on_singleton_guard; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX index_communities_on_singleton_guard ON public.communities USING btree (singleton_guard);


--
-- Name: index_communities_on_slug; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX index_communities_on_slug ON public.communities USING btree (slug);


--
-- Name: index_events_on_start_date; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_events_on_start_date ON public.events USING btree (start_date);


--
-- Name: index_friendly_id_slugs_on_slug_and_sluggable_type; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_friendly_id_slugs_on_slug_and_sluggable_type ON public.friendly_id_slugs USING btree (slug, sluggable_type);


--
-- Name: index_friendly_id_slugs_on_slug_and_sluggable_type_and_scope; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX index_friendly_id_slugs_on_slug_and_sluggable_type_and_scope ON public.friendly_id_slugs USING btree (slug, sluggable_type, scope);


--
-- Name: index_friendly_id_slugs_on_sluggable_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_friendly_id_slugs_on_sluggable_id ON public.friendly_id_slugs USING btree (sluggable_id);


--
-- Name: index_friendly_id_slugs_on_sluggable_type; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_friendly_id_slugs_on_sluggable_type ON public.friendly_id_slugs USING btree (sluggable_type);


--
-- Name: index_guest_room_reservations_on_date; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX index_guest_room_reservations_on_date ON public.guest_room_reservations USING btree (date);


--
-- Name: index_guest_room_reservations_on_resident_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_guest_room_reservations_on_resident_id ON public.guest_room_reservations USING btree (resident_id);


--
-- Name: index_guests_on_meal_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_guests_on_meal_id ON public.guests USING btree (meal_id);


--
-- Name: index_guests_on_resident_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_guests_on_resident_id ON public.guests USING btree (resident_id);


--
-- Name: index_keys_on_identity_type_and_identity_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_keys_on_identity_type_and_identity_id ON public.keys USING btree (identity_type, identity_id);


--
-- Name: index_keys_on_token; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX index_keys_on_token ON public.keys USING btree (token);


--
-- Name: index_meal_residents_on_meal_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_meal_residents_on_meal_id ON public.meal_residents USING btree (meal_id);


--
-- Name: index_meal_residents_on_meal_id_and_resident_id; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX index_meal_residents_on_meal_id_and_resident_id ON public.meal_residents USING btree (meal_id, resident_id);


--
-- Name: index_meal_residents_on_resident_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_meal_residents_on_resident_id ON public.meal_residents USING btree (resident_id);


--
-- Name: index_meals_on_date; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX index_meals_on_date ON public.meals USING btree (date);


--
-- Name: index_meals_on_reconciliation_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_meals_on_reconciliation_id ON public.meals USING btree (reconciliation_id);


--
-- Name: index_meals_on_rotation_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_meals_on_rotation_id ON public.meals USING btree (rotation_id);


--
-- Name: index_recon_balances_on_recon_id_and_resident_id; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX index_recon_balances_on_recon_id_and_resident_id ON public.reconciliation_balances USING btree (reconciliation_id, resident_id);


--
-- Name: index_reconciliation_balances_on_reconciliation_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_reconciliation_balances_on_reconciliation_id ON public.reconciliation_balances USING btree (reconciliation_id);


--
-- Name: index_reconciliation_balances_on_resident_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_reconciliation_balances_on_resident_id ON public.reconciliation_balances USING btree (resident_id);


--
-- Name: index_resident_balances_on_resident_id; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX index_resident_balances_on_resident_id ON public.resident_balances USING btree (resident_id);


--
-- Name: index_residents_on_email; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX index_residents_on_email ON public.residents USING btree (email);


--
-- Name: index_residents_on_name; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX index_residents_on_name ON public.residents USING btree (name);


--
-- Name: index_residents_on_reset_password_token; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX index_residents_on_reset_password_token ON public.residents USING btree (reset_password_token);


--
-- Name: index_residents_on_unit_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_residents_on_unit_id ON public.residents USING btree (unit_id);


--
-- Name: index_units_on_name; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX index_units_on_name ON public.units USING btree (name);


--
-- Name: bills bills_reject_settled_write; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER bills_reject_settled_write BEFORE INSERT OR DELETE OR UPDATE ON public.bills FOR EACH ROW EXECUTE FUNCTION public.comeals_reject_settled_child_write();


--
-- Name: guests guests_reject_settled_write; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER guests_reject_settled_write BEFORE INSERT OR DELETE OR UPDATE ON public.guests FOR EACH ROW EXECUTE FUNCTION public.comeals_reject_settled_child_write();


--
-- Name: meal_residents meal_residents_reject_settled_write; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER meal_residents_reject_settled_write BEFORE INSERT OR DELETE OR UPDATE ON public.meal_residents FOR EACH ROW EXECUTE FUNCTION public.comeals_reject_settled_child_write();


--
-- Name: meals meals_protect_settled; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER meals_protect_settled BEFORE DELETE OR UPDATE ON public.meals FOR EACH ROW EXECUTE FUNCTION public.comeals_protect_settled_meal();


--
-- Name: communities prevent_community_delete; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER prevent_community_delete BEFORE DELETE ON public.communities FOR EACH ROW EXECUTE FUNCTION public.prevent_community_delete();


--
-- Name: meals fk_rails_0336f048cd; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.meals
    ADD CONSTRAINT fk_rails_0336f048cd FOREIGN KEY (community_id) REFERENCES public.communities(id);


--
-- Name: meal_residents fk_rails_0ae5bb5322; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.meal_residents
    ADD CONSTRAINT fk_rails_0ae5bb5322 FOREIGN KEY (community_id) REFERENCES public.communities(id);


--
-- Name: admin_users fk_rails_0f9c3805ac; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.admin_users
    ADD CONSTRAINT fk_rails_0f9c3805ac FOREIGN KEY (community_id) REFERENCES public.communities(id);


--
-- Name: guest_room_reservations fk_rails_32fcb582b6; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.guest_room_reservations
    ADD CONSTRAINT fk_rails_32fcb582b6 FOREIGN KEY (resident_id) REFERENCES public.residents(id);


--
-- Name: events fk_rails_3451eeb877; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.events
    ADD CONSTRAINT fk_rails_3451eeb877 FOREIGN KEY (community_id) REFERENCES public.communities(id);


--
-- Name: common_house_reservations fk_rails_38e00fcb6a; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.common_house_reservations
    ADD CONSTRAINT fk_rails_38e00fcb6a FOREIGN KEY (community_id) REFERENCES public.communities(id);


--
-- Name: guest_room_reservations fk_rails_3a0c325b9d; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.guest_room_reservations
    ADD CONSTRAINT fk_rails_3a0c325b9d FOREIGN KEY (community_id) REFERENCES public.communities(id);


--
-- Name: reconciliation_balances fk_rails_4123ddbc11; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.reconciliation_balances
    ADD CONSTRAINT fk_rails_4123ddbc11 FOREIGN KEY (reconciliation_id) REFERENCES public.reconciliations(id);


--
-- Name: guests fk_rails_47de94cfe5; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.guests
    ADD CONSTRAINT fk_rails_47de94cfe5 FOREIGN KEY (meal_id) REFERENCES public.meals(id);


--
-- Name: meals fk_rails_4ac0d4ffd3; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.meals
    ADD CONSTRAINT fk_rails_4ac0d4ffd3 FOREIGN KEY (reconciliation_id) REFERENCES public.reconciliations(id);


--
-- Name: common_house_reservations fk_rails_52e17e5c72; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.common_house_reservations
    ADD CONSTRAINT fk_rails_52e17e5c72 FOREIGN KEY (resident_id) REFERENCES public.residents(id);


--
-- Name: reconciliation_balances fk_rails_565168ad8a; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.reconciliation_balances
    ADD CONSTRAINT fk_rails_565168ad8a FOREIGN KEY (resident_id) REFERENCES public.residents(id);


--
-- Name: reconciliations fk_rails_6c1fea41cb; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.reconciliations
    ADD CONSTRAINT fk_rails_6c1fea41cb FOREIGN KEY (community_id) REFERENCES public.communities(id);


--
-- Name: bills fk_rails_72ad19dcbf; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.bills
    ADD CONSTRAINT fk_rails_72ad19dcbf FOREIGN KEY (community_id) REFERENCES public.communities(id);


--
-- Name: meal_residents fk_rails_7bb4e17f2a; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.meal_residents
    ADD CONSTRAINT fk_rails_7bb4e17f2a FOREIGN KEY (resident_id) REFERENCES public.residents(id);


--
-- Name: residents fk_rails_8ddf6a82d6; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.residents
    ADD CONSTRAINT fk_rails_8ddf6a82d6 FOREIGN KEY (unit_id) REFERENCES public.units(id);


--
-- Name: guests fk_rails_96051864fd; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.guests
    ADD CONSTRAINT fk_rails_96051864fd FOREIGN KEY (resident_id) REFERENCES public.residents(id);


--
-- Name: bills fk_rails_a4b9083e79; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.bills
    ADD CONSTRAINT fk_rails_a4b9083e79 FOREIGN KEY (meal_id) REFERENCES public.meals(id);


--
-- Name: meals fk_rails_a7c2d1d4f4; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.meals
    ADD CONSTRAINT fk_rails_a7c2d1d4f4 FOREIGN KEY (rotation_id) REFERENCES public.rotations(id);


--
-- Name: resident_balances fk_rails_b4d137a40d; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.resident_balances
    ADD CONSTRAINT fk_rails_b4d137a40d FOREIGN KEY (resident_id) REFERENCES public.residents(id);


--
-- Name: units fk_rails_b860cf198b; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.units
    ADD CONSTRAINT fk_rails_b860cf198b FOREIGN KEY (community_id) REFERENCES public.communities(id);


--
-- Name: residents fk_rails_bbc4659b07; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.residents
    ADD CONSTRAINT fk_rails_bbc4659b07 FOREIGN KEY (community_id) REFERENCES public.communities(id);


--
-- Name: meal_residents fk_rails_c5855254a4; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.meal_residents
    ADD CONSTRAINT fk_rails_c5855254a4 FOREIGN KEY (meal_id) REFERENCES public.meals(id);


--
-- Name: rotations fk_rails_d1c6b2a31e; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.rotations
    ADD CONSTRAINT fk_rails_d1c6b2a31e FOREIGN KEY (community_id) REFERENCES public.communities(id);


--
-- Name: bills fk_rails_d7e3fd1337; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.bills
    ADD CONSTRAINT fk_rails_d7e3fd1337 FOREIGN KEY (resident_id) REFERENCES public.residents(id);


--
-- PostgreSQL database dump complete
--

SET search_path TO "$user", public;

INSERT INTO "schema_migrations" (version) VALUES
('20260707100000'),
('20260423170000'),
('20260423160000'),
('20260421150000'),
('20260421140000'),
('20260421131127'),
('20260410032155'),
('20260409152612'),
('20260408000002'),
('20260408000001'),
('20260407223500'),
('20260407223250'),
('20260407223010'),
('20260407222736'),
('20260407000001'),
('20260406000001'),
('20260404024713'),
('20260404022429'),
('20260328045422'),
('20260327000003'),
('20260327000002'),
('20260327000001'),
('20260326000005'),
('20260326000004'),
('20260326000003'),
('20260326000002'),
('20260326000001'),
('20200418183434'),
('20200306234101'),
('20200229234138'),
('20180729204215'),
('20180508231433'),
('20180430225602'),
('20180323165313'),
('20180313172509'),
('20180313163638'),
('20180306184334'),
('20180306183232'),
('20171127154541'),
('20171122185007'),
('20171114001858'),
('20171113222604'),
('20170913210922'),
('20170815141458'),
('20170724165619'),
('20170530165903'),
('20170518210633'),
('20170518172351'),
('20170518171751'),
('20170518171327'),
('20170518170655'),
('20170518170333'),
('20170518170148'),
('20170518170000'),
('20170518165656'),
('20170516224345'),
('20170515164827');

