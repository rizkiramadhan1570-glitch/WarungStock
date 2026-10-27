-- ==============================================================================
-- WARUNGSTOCK - SUPABASE POSTGRESQL SCHEMA & ROW LEVEL SECURITY (RLS)
-- Sesuai Standar Aplikasi Manajemen Persediaan UMKM Warung Indonesia
-- ==============================================================================

-- 1. EXTENSIONS
CREATE EXTENSION IF NOT EXISTS "uuid-ossp";

-- 2. ENUM TYPES
CREATE TYPE user_role AS ENUM ('owner', 'cashier', 'warehouse');
CREATE TYPE product_unit AS ENUM ('pcs', 'bungkus', 'botol', 'kaleng', 'renteng', 'pak', 'dus');
CREATE TYPE payment_method AS ENUM ('cash', 'transfer', 'qris');
CREATE TYPE transaction_status AS ENUM ('completed', 'cancelled');
CREATE TYPE purchase_status AS ENUM ('draft', 'completed', 'cancelled');
CREATE TYPE stock_movement_type AS ENUM ('sale', 'purchase', 'adjustment', 'sale_cancellation', 'purchase_cancellation');
CREATE TYPE opname_reason AS ENUM ('rusak', 'kedaluwarsa', 'hilang', 'selisih_hitung', 'koreksi_pencatatan');

-- 3. PROFILES / USERS
CREATE TABLE IF NOT EXISTS profiles (
    id UUID PRIMARY KEY REFERENCES auth.users(id) ON DELETE CASCADE,
    name VARCHAR(150) NOT NULL,
    role user_role NOT NULL DEFAULT 'cashier',
    phone VARCHAR(30),
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

-- 4. CATEGORIES
CREATE TABLE IF NOT EXISTS categories (
    id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    name VARCHAR(100) NOT NULL UNIQUE,
    description TEXT,
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

-- 5. SUPPLIERS
CREATE TABLE IF NOT EXISTS suppliers (
    id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    name VARCHAR(120) NOT NULL,
    company VARCHAR(150) NOT NULL,
    phone VARCHAR(30) NOT NULL,
    address TEXT,
    supplied_products TEXT,
    notes TEXT,
    is_archived BOOLEAN NOT NULL DEFAULT FALSE,
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

-- 6. PRODUCTS
CREATE TABLE IF NOT EXISTS products (
    id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    sku VARCHAR(50) NOT NULL UNIQUE,
    barcode VARCHAR(100),
    name VARCHAR(200) NOT NULL,
    category_id UUID NOT NULL REFERENCES categories(id) ON DELETE RESTRICT,
    unit product_unit NOT NULL DEFAULT 'pcs',
    cost_price NUMERIC(12, 2) NOT NULL CHECK (cost_price >= 0),
    selling_price NUMERIC(12, 2) NOT NULL CHECK (selling_price >= 0),
    stock INTEGER NOT NULL DEFAULT 0 CHECK (stock >= 0), -- Melindungi dari stok negatif di level database!
    min_stock INTEGER NOT NULL DEFAULT 5 CHECK (min_stock >= 0),
    supplier_id UUID REFERENCES suppliers(id) ON DELETE SET NULL,
    expiry_date DATE,
    is_archived BOOLEAN NOT NULL DEFAULT FALSE,
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

-- INDEXES FOR FAST LOOKUP
CREATE INDEX IF NOT EXISTS idx_products_sku ON products(sku);
CREATE INDEX IF NOT EXISTS idx_products_barcode ON products(barcode);
CREATE INDEX IF NOT EXISTS idx_products_name ON products USING gin(to_tsvector('indonesian', name));
CREATE INDEX IF NOT EXISTS idx_products_category ON products(category_id);

-- 7. SALES (PENJUALAN KASIR)
CREATE TABLE IF NOT EXISTS sales (
    id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    invoice_number VARCHAR(50) NOT NULL UNIQUE,
    user_id UUID REFERENCES auth.users(id) ON DELETE SET NULL,
    cashier_name VARCHAR(150) NOT NULL,
    subtotal NUMERIC(12, 2) NOT NULL CHECK (subtotal >= 0),
    discount NUMERIC(12, 2) NOT NULL DEFAULT 0 CHECK (discount >= 0),
    total NUMERIC(12, 2) NOT NULL CHECK (total >= 0),
    payment_method payment_method NOT NULL DEFAULT 'cash',
    payment_details JSONB DEFAULT '{}'::jsonb, -- Rincian QRIS (NMID, RRN) atau Transfer Bank (Nama Bank, No Rek, Ref)
    cash_received NUMERIC(12, 2) NOT NULL CHECK (cash_received >= 0),
    change NUMERIC(12, 2) NOT NULL DEFAULT 0 CHECK (change >= 0),
    status transaction_status NOT NULL DEFAULT 'completed',
    cancellation_reason TEXT,
    cancelled_at TIMESTAMPTZ,
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE INDEX IF NOT EXISTS idx_sales_invoice ON sales(invoice_number);
CREATE INDEX IF NOT EXISTS idx_sales_date ON sales(created_at);

-- 8. SALE ITEMS (DETAIL BARANG TERJUAL DENGAN HPP HISTORIS)
CREATE TABLE IF NOT EXISTS sale_items (
    id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    sale_id UUID NOT NULL REFERENCES sales(id) ON DELETE CASCADE,
    product_id UUID NOT NULL REFERENCES products(id) ON DELETE RESTRICT,
    product_name VARCHAR(200) NOT NULL,
    sku VARCHAR(50) NOT NULL,
    unit VARCHAR(20) NOT NULL,
    quantity INTEGER NOT NULL CHECK (quantity > 0),
    selling_price NUMERIC(12, 2) NOT NULL CHECK (selling_price >= 0),
    cost_price NUMERIC(12, 2) NOT NULL CHECK (cost_price >= 0), -- Menjaga keabsahan perhitungan HPP jika harga master berubah di kemudian hari
    subtotal NUMERIC(12, 2) NOT NULL CHECK (subtotal >= 0)
);

CREATE INDEX IF NOT EXISTS idx_sale_items_sale ON sale_items(sale_id);
CREATE INDEX IF NOT EXISTS idx_sale_items_product ON sale_items(product_id);

-- 9. PURCHASES (PEMBELIAN / KULAKAN DARI PEMASOK)
CREATE TABLE IF NOT EXISTS purchases (
    id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    purchase_number VARCHAR(50) NOT NULL UNIQUE,
    supplier_id UUID NOT NULL REFERENCES suppliers(id) ON DELETE RESTRICT,
    supplier_name VARCHAR(150) NOT NULL,
    total_amount NUMERIC(12, 2) NOT NULL CHECK (total_amount >= 0),
    status purchase_status NOT NULL DEFAULT 'draft',
    notes TEXT,
    stock_updated BOOLEAN NOT NULL DEFAULT FALSE,
    cancellation_reason TEXT,
    cancelled_at TIMESTAMPTZ,
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE INDEX IF NOT EXISTS idx_purchases_number ON purchases(purchase_number);
CREATE INDEX IF NOT EXISTS idx_purchases_date ON purchases(created_at);

-- 10. PURCHASE ITEMS
CREATE TABLE IF NOT EXISTS purchase_items (
    id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    purchase_id UUID NOT NULL REFERENCES purchases(id) ON DELETE CASCADE,
    product_id UUID NOT NULL REFERENCES products(id) ON DELETE RESTRICT,
    product_name VARCHAR(200) NOT NULL,
    sku VARCHAR(50) NOT NULL,
    unit VARCHAR(20) NOT NULL,
    quantity INTEGER NOT NULL CHECK (quantity > 0),
    cost_price NUMERIC(12, 2) NOT NULL CHECK (cost_price >= 0),
    subtotal NUMERIC(12, 2) NOT NULL CHECK (subtotal >= 0)
);

-- 11. STOCK MOVEMENTS (AUDIT TRAIL LOG PERGERAKAN STOK)
CREATE TABLE IF NOT EXISTS stock_movements (
    id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    product_id UUID NOT NULL REFERENCES products(id) ON DELETE RESTRICT,
    product_name VARCHAR(200) NOT NULL,
    sku VARCHAR(50) NOT NULL,
    stock_before INTEGER NOT NULL,
    change INTEGER NOT NULL,
    stock_after INTEGER NOT NULL CHECK (stock_after >= 0),
    type stock_movement_type NOT NULL,
    reference_number VARCHAR(80) NOT NULL,
    notes TEXT,
    user_name VARCHAR(150) NOT NULL,
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE INDEX IF NOT EXISTS idx_stock_movements_prod ON stock_movements(product_id);
CREATE INDEX IF NOT EXISTS idx_stock_movements_date ON stock_movements(created_at);

-- 12. STOCK OPNAMES & ADJUSTMENTS
CREATE TABLE IF NOT EXISTS stock_opnames (
    id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    opname_number VARCHAR(50) NOT NULL UNIQUE,
    product_id UUID NOT NULL REFERENCES products(id) ON DELETE RESTRICT,
    product_name VARCHAR(200) NOT NULL,
    sku VARCHAR(50) NOT NULL,
    system_stock INTEGER NOT NULL,
    physical_stock INTEGER NOT NULL CHECK (physical_stock >= 0),
    discrepancy INTEGER NOT NULL,
    reason opname_reason NOT NULL,
    notes TEXT,
    adjusted_by VARCHAR(150) NOT NULL,
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

-- ==============================================================================
-- DATABASE FUNCTIONS & STORED PROCEDURES (ATOMICITY GUARANTEE)
-- ==============================================================================

-- FUNGSI: PROSES PENJUALAN SECARA ATOMIK & CEK STOK
CREATE OR REPLACE FUNCTION process_sale_transaction(
    p_user_id UUID,
    p_cashier_name VARCHAR,
    p_items JSONB,
    p_discount NUMERIC,
    p_payment_method payment_method,
    p_cash_received NUMERIC
) RETURNS JSONB AS $$
DECLARE
    v_sale_id UUID;
    v_invoice_number VARCHAR;
    v_subtotal NUMERIC := 0;
    v_total NUMERIC := 0;
    v_change NUMERIC := 0;
    v_item JSONB;
    v_prod_id UUID;
    v_qty INTEGER;
    v_prod RECORD;
    v_item_subtotal NUMERIC;
BEGIN
    -- Buat nomor invoice baru
    v_invoice_number := 'TRX-' || TO_CHAR(NOW(), 'YYYYMMDD') || '-' || LPAD(FLOOR(RANDOM() * 9000 + 1000)::TEXT, 4, '0');

    -- Validasi ketersediaan stok semua barang terlebih dahulu
    FOR v_item IN SELECT * FROM jsonb_array_elements(p_items)
    LOOP
        v_prod_id := (v_item->>'productId')::UUID;
        v_qty := (v_item->>'quantity')::INTEGER;

        SELECT id, name, unit, selling_price, cost_price, stock INTO v_prod
        FROM products WHERE id = v_prod_id FOR UPDATE;

        IF NOT FOUND THEN
            RAISE EXCEPTION 'Produk dengan ID % tidak ditemukan!', v_prod_id;
        END IF;

        IF v_prod.stock < v_qty THEN
            RAISE EXCEPTION 'Stok tidak mencukupi untuk %! Stok sisa: %, diminta: %', v_prod.name, v_prod.stock, v_qty;
        END IF;

        v_item_subtotal := v_prod.selling_price * v_qty;
        v_subtotal := v_subtotal + v_item_subtotal;
    END LOOP;

    v_total := GREATEST(0, v_subtotal - COALESCE(p_discount, 0));
    IF p_payment_method = 'cash' AND p_cash_received < v_total THEN
        RAISE EXCEPTION 'Uang tunai yang dibayarkan kurang dari total tagihan!';
    END IF;

    v_change := CASE WHEN p_payment_method = 'cash' THEN GREATEST(0, p_cash_received - v_total) ELSE 0 END;

    -- Simpan Header Penjualan
    INSERT INTO sales (invoice_number, user_id, cashier_name, subtotal, discount, total, payment_method, cash_received, change, status)
    VALUES (v_invoice_number, p_user_id, p_cashier_name, v_subtotal, COALESCE(p_discount, 0), v_total, p_payment_method, p_cash_received, v_change, 'completed')
    RETURNING id INTO v_sale_id;

    -- Potong stok dan catat item serta log pergerakan stok
    FOR v_item IN SELECT * FROM jsonb_array_elements(p_items)
    LOOP
        v_prod_id := (v_item->>'productId')::UUID;
        v_qty := (v_item->>'quantity')::INTEGER;

        SELECT id, name, sku, unit, selling_price, cost_price, stock INTO v_prod
        FROM products WHERE id = v_prod_id;

        -- Kurangi stok
        UPDATE products
        SET stock = stock - v_qty, updated_at = NOW()
        WHERE id = v_prod_id;

        -- Simpan item
        INSERT INTO sale_items (sale_id, product_id, product_name, sku, unit, quantity, selling_price, cost_price, subtotal)
        VALUES (v_sale_id, v_prod_id, v_prod.name, v_prod.sku, v_prod.unit, v_qty, v_prod.selling_price, v_prod.cost_price, (v_prod.selling_price * v_qty));

        -- Catat pergerakan stok
        INSERT INTO stock_movements (product_id, product_name, sku, stock_before, change, stock_after, type, reference_number, notes, user_name)
        VALUES (v_prod_id, v_prod.name, v_prod.sku, v_prod.stock, -v_qty, (v_prod.stock - v_qty), 'sale', v_invoice_number, 'Penjualan Kasir ' || v_invoice_number, p_cashier_name);
    END LOOP;

    RETURN jsonb_build_object(
        'success', true,
        'invoiceNumber', v_invoice_number,
        'saleId', v_sale_id,
        'total', v_total,
        'change', v_change
    );
END;
$$ LANGUAGE plpgsql;

-- FUNGSI: PEMBATALAN TRANSAKSI PENJUALAN & PENGEMBALIAN STOK
CREATE OR REPLACE FUNCTION cancel_sale_transaction(
    p_sale_id UUID,
    p_reason TEXT,
    p_user_name VARCHAR
) RETURNS JSONB AS $$
DECLARE
    v_sale RECORD;
    v_item RECORD;
    v_prod RECORD;
BEGIN
    SELECT * INTO v_sale FROM sales WHERE id = p_sale_id FOR UPDATE;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'Transaksi tidak ditemukan!';
    END IF;
    IF v_sale.status = 'cancelled' THEN
        RAISE EXCEPTION 'Transaksi ini sudah dibatalkan sebelumnya!';
    END IF;

    -- Kembalikan stok untuk semua item
    FOR v_item IN SELECT * FROM sale_items WHERE sale_id = p_sale_id
    LOOP
        SELECT * INTO v_prod FROM products WHERE id = v_item.product_id FOR UPDATE;
        
        UPDATE products
        SET stock = stock + v_item.quantity, updated_at = NOW()
        WHERE id = v_item.product_id;

        INSERT INTO stock_movements (product_id, product_name, sku, stock_before, change, stock_after, type, reference_number, notes, user_name)
        VALUES (v_prod.id, v_prod.name, v_prod.sku, v_prod.stock, v_item.quantity, (v_prod.stock + v_item.quantity), 'sale_cancellation', v_sale.invoice_number, 'Pembatalan Struk: ' || p_reason, p_user_name);
    END LOOP;

    -- Tandai transaksi batal
    UPDATE sales
    SET status = 'cancelled', cancellation_reason = p_reason, cancelled_at = NOW()
    WHERE id = p_sale_id;

    RETURN jsonb_build_object('success', true, 'message', 'Transaksi berhasil dibatalkan dan stok dikembalikan.');
END;
$$ LANGUAGE plpgsql;

-- ==============================================================================
-- ROW LEVEL SECURITY (RLS) POLICIES
-- ==============================================================================
ALTER TABLE profiles ENABLE ROW LEVEL SECURITY;
ALTER TABLE categories ENABLE ROW LEVEL SECURITY;
ALTER TABLE products ENABLE ROW LEVEL SECURITY;
ALTER TABLE suppliers ENABLE ROW LEVEL SECURITY;
ALTER TABLE sales ENABLE ROW LEVEL SECURITY;
ALTER TABLE sale_items ENABLE ROW LEVEL SECURITY;
ALTER TABLE purchases ENABLE ROW LEVEL SECURITY;
ALTER TABLE purchase_items ENABLE ROW LEVEL SECURITY;
ALTER TABLE stock_movements ENABLE ROW LEVEL SECURITY;
ALTER TABLE stock_opnames ENABLE ROW LEVEL SECURITY;

-- KEBENARAN AKSES:
-- 1. Semua user terotentikasi dapat melihat kategori & produk
CREATE POLICY "Public Read Categories" ON categories FOR SELECT USING (true);
CREATE POLICY "Public Read Products" ON products FOR SELECT USING (true);

-- 2. Kasir hanya dapat membuat sales & melihat sales
CREATE POLICY "Cashier Sales Insert" ON sales FOR INSERT WITH CHECK (auth.role() = 'authenticated');
CREATE POLICY "Cashier Sales Select" ON sales FOR SELECT USING (auth.role() = 'authenticated');
CREATE POLICY "Cashier Sale Items" ON sale_items FOR ALL USING (auth.role() = 'authenticated');

-- 3. Owner & Petugas Gudang dapat mengelola produk, pembelian, opname
CREATE POLICY "Admin All Products" ON products FOR ALL USING (
    EXISTS (SELECT 1 FROM profiles WHERE profiles.id = auth.uid() AND profiles.role IN ('owner', 'warehouse'))
);
CREATE POLICY "Admin All Purchases" ON purchases FOR ALL USING (
    EXISTS (SELECT 1 FROM profiles WHERE profiles.id = auth.uid() AND profiles.role IN ('owner', 'warehouse'))
);
