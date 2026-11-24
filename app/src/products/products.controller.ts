import { Controller, Get } from '@nestjs/common';
import { DatabaseService } from '../database/database.service.js';

interface Product {
  id: number;
  name: string;
  price_cents: number;
}

@Controller('api/products')
export class ProductsController {
  constructor(private readonly db: DatabaseService) {}

  @Get()
  async list(): Promise<Product[]> {
    const { rows } = await this.db.pool.query<Product>(
      'SELECT id, name, price_cents FROM products ORDER BY id',
    );
    return rows;
  }
}
